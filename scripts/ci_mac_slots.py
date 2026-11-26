"""Deterministic admission metadata; never changes matrix identity or ordering."""
SLOT_COUNT = 5


def validate_macos_slots(rows, identity_fields):
    if not isinstance(rows, list) or not rows:
        raise ValueError('macOS matrix must contain rows')
    seen = set()
    for index, row in enumerate(rows):
        if not isinstance(row, dict) or any(not isinstance(row.get(key), str) or not row[key]
                                            for key in identity_fields):
            raise ValueError('macOS matrix row has incomplete identity')
        identity = tuple(row[key] for key in identity_fields)
        if identity in seen:
            raise ValueError(f'Duplicate macOS matrix identity: {identity}')
        seen.add(identity)
        slot = row.get('macos_slot')
        if type(slot) is not int or slot != index % SLOT_COUNT:
            raise ValueError(f'Invalid macOS slot at row {index}: {slot!r}')
    return rows


def with_macos_slots(rows, identity_fields):
    if not isinstance(rows, list) or any(not isinstance(row, dict) or 'macos_slot' in row for row in rows):
        raise ValueError('Assign slots only to original unassigned matrix rows')
    result = [{**row, 'macos_slot': index % SLOT_COUNT} for index, row in enumerate(rows)]
    return validate_macos_slots(result, identity_fields)


BITRISE_POOLS = ("A1", "A2")
BITRISE_SLOTS_PER_POOL = 6


def with_bitrise_slots(rows, identity_fields, estimated_seconds, *, first_pool="A1", a3_enabled=False):
    """Assign whole jobs longest-first across the enabled provider lanes.

    Row order, identity and GitHub fallback metadata are preserved. Durations
    are scheduling estimates, not provider speed or currently available capacity.
    """
    if first_pool not in BITRISE_POOLS or not isinstance(rows, list) or not rows:
        raise ValueError("Expected nonempty jobs and a reviewed Bitrise pool")
    if len(estimated_seconds) != len(rows) or any(type(n) is not int or n <= 0 for n in estimated_seconds):
        raise ValueError("Every Bitrise job needs a positive integer duration estimate")
    identities = []
    for row in rows:
        if (not isinstance(row, dict) or any(not isinstance(row.get(k), str) or not row[k] for k in identity_fields)
                or any(k in row for k in ("provider", "pool_slot", "m4_slot"))):
            raise ValueError("Assign pools only to original, identified matrix rows")
        identities.append(tuple(row[k] for k in identity_fields))
    if len(set(identities)) != len(rows):
        raise ValueError("Duplicate Bitrise job identity")
    pools = (first_pool, next(p for p in BITRISE_POOLS if p != first_pool))
    lanes = [(pool, slot) for slot in range(BITRISE_SLOTS_PER_POOL) for pool in pools]
    if a3_enabled:
        # A1 and A2 share six M4 machines. Alternate each of their first six
        # combined lanes with one of the six separately budgeted M2 machines.
        m4_lanes = lanes[:BITRISE_SLOTS_PER_POOL]
        lanes = [lane for slot, m4 in enumerate(m4_lanes) for lane in (m4, ("A3", slot))]
    totals = [0] * len(lanes)
    result = [dict(row) for row in rows]
    for index in sorted(range(len(rows)), key=lambda i: (-estimated_seconds[i], identities[i])):
        lane = min(range(len(lanes)), key=totals.__getitem__)
        pool, slot = lanes[lane]
        result[index].update(provider="bitrise-" + pool, pool_slot=slot)
        totals[lane] += estimated_seconds[index]
    return result
