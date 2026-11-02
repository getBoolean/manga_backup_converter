"""Patch tachibk-converter's schema generator for newer Kotlin backup models.

Usage: python patch_schema_generator.py <path/to/generate_schemas.py>

- Maps Kotlin `ByteArray` to protobuf `bytes` (Mihon/SY `memo` fields).
- Accepts annotations before `val` at the start of a class body, e.g.
  `data class IntPreferenceValue(@EncodeDefault val value: Int = 0)` in SY.

Each patch is skipped if the generator already handles it, and the script
fails if a patch can no longer be applied, so upstream changes surface loudly.
"""

import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text(encoding='utf-8')

PATCHES = [
    (
        "'ByteArray'",
        "    'Char': 'string',\n",
        "    'Char': 'string',\n    'ByteArray': 'bytes',\n",
    ),
    (
        r"|^(?:@\w+\s+)*)va[rl]",
        r"|^)va[rl]",
        r"|^(?:@\w+\s+)*)va[rl]",
    ),
]

for already_applied, old, new in PATCHES:
    if already_applied in source:
        continue
    if old not in source:
        sys.exit(f'::error::Cannot patch schema generator: {old!r} not found')
    source = source.replace(old, new, 1)

path.write_text(source, encoding='utf-8')
print(f'Patched {path}')
