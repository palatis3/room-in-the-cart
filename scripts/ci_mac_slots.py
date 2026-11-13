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
