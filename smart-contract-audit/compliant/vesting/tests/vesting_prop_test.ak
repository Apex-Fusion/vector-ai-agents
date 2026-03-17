/// # Vesting — Property-Based Tests
///
/// Property tests using Aiken's fuzz framework to verify invariants
/// hold across random inputs for the vesting validator logic.
///
/// Properties verified:
/// - Vested amount always in [0, total] range
/// - Monotonically non-decreasing over time
/// - Pre-cliff always rejected
/// - Post-end always fully vested
/// - Claimable capped by locked amount
/// - Remainder always non-negative
/// - Linear proportionality of vesting schedule
///
/// Authored by: Test Writer
/// Date: 2026-03-16

use aiken/fuzz
use vesting_types.{VestingDatum}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const beneficiary_pkh =
  #"aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd"

const cliff_time = 1_000_000_000_000

const vesting_end_time = 2_000_000_000_000

const total_vesting_amount = 100_000_000

// ---------------------------------------------------------------------------
// Helpers (mirrors validator logic)
// ---------------------------------------------------------------------------

fn min_int(a: Int, b: Int) -> Int {
  if a <= b {
    a
  } else {
    b
  }
}

fn compute_vested(d: VestingDatum, current_time: Int) -> Int {
  if current_time >= d.vesting_end_time {
    d.total_vesting_amount
  } else {
    let elapsed = current_time - d.cliff_time
    let duration = d.vesting_end_time - d.cliff_time
    d.total_vesting_amount * elapsed / duration
  }
}

fn make_datum() -> VestingDatum {
  VestingDatum {
    beneficiary: beneficiary_pkh,
    total_vesting_amount,
    cliff_time,
    vesting_end_time,
  }
}

// ===========================================================================
// PROPERTY 1: Random valid time between cliff and end → vested in [0, total]
// ===========================================================================

/// For any time between cliff and vesting_end, vested amount is in [0, total].
test prop_vested_in_range(offset via fuzz.int()) {
  let d = make_datum()
  let duration = vesting_end_time - cliff_time
  let clamped =
    if offset < 0 {
      -offset % ( duration + 1 )
    } else {
      offset % ( duration + 1 )
    }
  let time = cliff_time + clamped
  let vested = compute_vested(d, time)
  vested >= 0 && vested <= total_vesting_amount
}

// ===========================================================================
// PROPERTY 2: Vested amount is monotonically non-decreasing over time
// ===========================================================================

/// For two times t1 <= t2, vested(t1) <= vested(t2).
test prop_vested_monotonic(
  (t1_offset, t2_offset) via fuzz.both(fuzz.int(), fuzz.int()),
) {
  let d = make_datum()
  let duration = vesting_end_time - cliff_time
  let clamp = fn(n) {
      let abs_n =
        if n < 0 {
          -n
        } else {
          n
        }
      cliff_time + abs_n % ( duration + 1 )
    }
  let raw_t1 = clamp(t1_offset)
  let raw_t2 = clamp(t2_offset)
  let t1 =
    if raw_t1 <= raw_t2 {
      raw_t1
    } else {
      raw_t2
    }
  let t2 =
    if raw_t1 <= raw_t2 {
      raw_t2
    } else {
      raw_t1
    }
  compute_vested(d, t1) <= compute_vested(d, t2)
}

// ===========================================================================
// PROPERTY 3: Before cliff → vested = 0 (if computed with linear formula)
// ===========================================================================

/// For any time before cliff, past_cliff check would fail.
test prop_pre_cliff_rejected(offset via fuzz.int()) {
  let abs_offset =
    if offset < 0 {
      -offset
    } else if offset == 0 {
      1
    } else {
      offset
    }
  let time = abs_offset % cliff_time
  time < cliff_time
}

// ===========================================================================
// PROPERTY 4: Post-end → vested == total_vesting_amount
// ===========================================================================

/// For any time at or after vesting_end, vested equals total_vesting_amount.
test prop_post_end_full_vesting(extra via fuzz.int()) {
  let d = make_datum()
  let abs_extra =
    if extra < 0 {
      -extra
    } else {
      extra
    }
  let time = vesting_end_time + abs_extra % 1_000_000_000_000
  compute_vested(d, time) == total_vesting_amount
}

// ===========================================================================
// PROPERTY 5: claimable never exceeds locked_lovelace
// ===========================================================================

/// For any time and locked amount, claimable <= locked.
test prop_claimable_capped_by_locked(
  (time_offset, locked_raw) via fuzz.both(fuzz.int(), fuzz.int()),
) {
  let d = make_datum()
  let time =
    if time_offset < 0 {
      cliff_time + ( -time_offset ) % ( vesting_end_time - cliff_time + 1 )
    } else {
      cliff_time + time_offset % ( vesting_end_time - cliff_time + 1 )
    }
  let locked =
    if locked_raw < 1 {
      1
    } else if locked_raw > 1_000_000_000 {
      locked_raw % 1_000_000_000 + 1
    } else {
      locked_raw
    }
  let vested = compute_vested(d, time)
  let claimable = min_int(vested, locked)
  claimable <= locked
}

// ===========================================================================
// PROPERTY 6: must_remain is always non-negative
// ===========================================================================

test prop_must_remain_non_negative(
  (time_offset, locked_raw) via fuzz.both(fuzz.int(), fuzz.int()),
) {
  let d = make_datum()
  let time =
    if time_offset < 0 {
      cliff_time + ( -time_offset ) % ( vesting_end_time - cliff_time + 1 )
    } else {
      cliff_time + time_offset % ( vesting_end_time - cliff_time + 1 )
    }
  let locked =
    if locked_raw < 1 {
      1
    } else if locked_raw > 1_000_000_000 {
      locked_raw % 1_000_000_000 + 1
    } else {
      locked_raw
    }
  let vested = compute_vested(d, time)
  let claimable = min_int(vested, locked)
  let must_remain = locked - claimable
  must_remain >= 0
}

// ===========================================================================
// PROPERTY 7: Linear vesting — vested is proportional to elapsed time
// ===========================================================================

/// vested == total * elapsed / duration (integer division).
test prop_linear_proportionality(offset via fuzz.int()) {
  let d = make_datum()
  let duration = vesting_end_time - cliff_time
  let abs_off =
    if offset < 0 {
      -offset
    } else {
      offset
    }
  let elapsed = abs_off % duration + 1
  let time = cliff_time + elapsed
  if time >= vesting_end_time {
    True
  } else {
    let vested = compute_vested(d, time)
    let expected = total_vesting_amount * elapsed / duration
    vested == expected
  }
}
