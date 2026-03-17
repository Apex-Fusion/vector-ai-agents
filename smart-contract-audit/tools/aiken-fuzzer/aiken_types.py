"""
aiken_types.py — Parse Aiken/Plutus blueprint JSON schemas into typed structures.

Understands the schema format produced by `aiken build` / `aiken check`:
  - Primitive types: integer, bytes
  - Constructor types (anyOf with dataType=constructor)
  - List types (dataType=list)
  - References ($ref → #/definitions/...)
  - Option types (recognized by title pattern or anyOf with None variant)
"""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any, Optional
import json
import re


# ---------------------------------------------------------------------------
# Type model
# ---------------------------------------------------------------------------

@dataclass
class AikenType:
    """Base class for all parsed Aiken/Plutus types."""
    title: str = ""
    description: str = ""


@dataclass
class IntType(AikenType):
    pass


@dataclass
class BytesType(AikenType):
    pass


@dataclass
class ListType(AikenType):
    item_type: Optional[AikenType] = None


@dataclass
class ConstructorField:
    title: str
    description: str
    field_type: Optional[AikenType] = None


@dataclass
class ConstructorVariant:
    title: str
    description: str
    index: int
    fields: list[ConstructorField] = field(default_factory=list)


@dataclass
class SumType(AikenType):
    """anyOf with multiple constructor variants (enum / tagged union)."""
    variants: list[ConstructorVariant] = field(default_factory=list)


@dataclass
class UnknownType(AikenType):
    raw: dict = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

class BlueprintParser:
    """
    Parses a Plutus blueprint JSON file and resolves all $ref references.

    Usage:
        parser = BlueprintParser.from_file("plutus.json")
        validator = parser.get_validator("simple_escrow.simple_escrow.spend")
        redeemer_type = validator["redeemer_type"]
        datum_type = validator["datum_type"]
    """

    def __init__(self, blueprint: dict):
        self.blueprint = blueprint
        self.definitions: dict[str, dict] = blueprint.get("definitions", {})

    @classmethod
    def from_file(cls, path: str) -> "BlueprintParser":
        with open(path) as f:
            return cls(json.load(f))

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def list_validators(self) -> list[str]:
        """Return all validator titles in the blueprint."""
        return [v["title"] for v in self.blueprint.get("validators", [])]

    def get_validator(self, title: str) -> dict:
        """
        Returns a dict with keys: title, datum_type, redeemer_type.
        Values are AikenType instances (or None if not present).
        """
        for v in self.blueprint.get("validators", []):
            if v["title"] == title:
                datum_schema = v.get("datum", {}).get("schema")
                redeemer_schema = v.get("redeemer", {}).get("schema")
                return {
                    "title": title,
                    "datum_type": self._resolve(datum_schema) if datum_schema else None,
                    "redeemer_type": self._resolve(redeemer_schema) if redeemer_schema else None,
                    "datum_title": v.get("datum", {}).get("title"),
                    "redeemer_title": v.get("redeemer", {}).get("title"),
                }
        raise KeyError(f"Validator '{title}' not found. Available: {self.list_validators()}")

    def get_all_validators(self) -> list[dict]:
        """Return parsed info for every validator."""
        result = []
        for v in self.blueprint.get("validators", []):
            result.append(self.get_validator(v["title"]))
        return result

    # ------------------------------------------------------------------
    # Internal resolution
    # ------------------------------------------------------------------

    def _resolve(self, schema: dict) -> AikenType:
        """Recursively resolve a schema node to an AikenType."""
        if schema is None:
            return UnknownType(title="unknown")

        # Empty schema (used for .else validators)
        if not schema:
            return UnknownType(title="any")

        # Follow $ref
        if "$ref" in schema:
            return self._resolve_ref(schema["$ref"])

        data_type = schema.get("dataType")

        if data_type == "integer":
            return IntType(title=schema.get("title", "Int"), description=schema.get("description", ""))

        if data_type == "bytes":
            return BytesType(title=schema.get("title", "ByteArray"), description=schema.get("description", ""))

        if data_type == "list":
            item_schema = schema.get("items")
            item_type = self._resolve(item_schema) if item_schema else None
            return ListType(
                title=schema.get("title", "List"),
                description=schema.get("description", ""),
                item_type=item_type,
            )

        # anyOf with constructor variants
        if "anyOf" in schema:
            variants = []
            for v in schema["anyOf"]:
                variant = self._parse_constructor_variant(v)
                variants.append(variant)
            return SumType(
                title=schema.get("title", ""),
                description=schema.get("description", ""),
                variants=variants,
            )

        return UnknownType(title=schema.get("title", "unknown"), raw=schema)

    def _resolve_ref(self, ref: str) -> AikenType:
        """Resolve a $ref like '#/definitions/escrow_types~1EscrowDatum'."""
        # Strip leading #/definitions/
        key = ref.replace("#/definitions/", "")
        # Unescape ~1 → /
        key = key.replace("~1", "/")

        if key not in self.definitions:
            return UnknownType(title=key)

        schema = self.definitions[key]
        resolved = self._resolve(schema)
        # Preserve title from definition key if not already set
        if not resolved.title:
            resolved.title = key.split("/")[-1]
        return resolved

    def _parse_constructor_variant(self, schema: dict) -> ConstructorVariant:
        fields = []
        for f in schema.get("fields", []):
            field_type = self._resolve(f) if f else None
            fields.append(ConstructorField(
                title=f.get("title", ""),
                description=f.get("description", ""),
                field_type=field_type,
            ))
        return ConstructorVariant(
            title=schema.get("title", ""),
            description=schema.get("description", ""),
            index=schema.get("index", 0),
            fields=fields,
        )


# ---------------------------------------------------------------------------
# Pretty printer for debugging
# ---------------------------------------------------------------------------

def describe_type(t: AikenType, indent: int = 0) -> str:
    pad = "  " * indent
    if isinstance(t, IntType):
        return f"{pad}Int"
    elif isinstance(t, BytesType):
        return f"{pad}ByteArray"
    elif isinstance(t, ListType):
        inner = describe_type(t.item_type, indent + 1) if t.item_type else "?"
        return f"{pad}List[\n{inner}\n{pad}]"
    elif isinstance(t, SumType):
        lines = [f"{pad}{t.title or 'SumType'} (variants={len(t.variants)})"]
        for v in t.variants:
            lines.append(f"{pad}  [{v.index}] {v.title}")
            for fld in v.fields:
                ftype = describe_type(fld.field_type, indent + 3) if fld.field_type else "?"
                lines.append(f"{pad}    .{fld.title}:\n{ftype}")
        return "\n".join(lines)
    elif isinstance(t, UnknownType):
        return f"{pad}Unknown({t.title})"
    return f"{pad}{type(t).__name__}"


if __name__ == "__main__":
    import sys
    path = sys.argv[1] if len(sys.argv) > 1 else "plutus.json"
    parser = BlueprintParser.from_file(path)
    print(f"Validators in {path}:")
    for v in parser.get_all_validators():
        print(f"\n{'='*60}")
        print(f"  {v['title']}")
        if v["datum_type"]:
            print(f"  DATUM:")
            print(describe_type(v["datum_type"], 2))
        if v["redeemer_type"]:
            print(f"  REDEEMER:")
            print(describe_type(v["redeemer_type"], 2))
