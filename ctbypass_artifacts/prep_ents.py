#!/usr/bin/env python3
import re
import sys
import os

for name in ['apsd', 'ids', 'apc']:
    src = f'/tmp/ts_build/{name}_orig_ents.xml'
    dst = f'/tmp/ts_build/{name}_final_ents.xml'
    with open(src) as f:
        c = f.read()
    # Remove seatbelt-profiles block
    c = re.sub(r'\s*<key>seatbelt-profiles</key>\s*<array>\s*<string>.*?</string>\s*</array>', '', c, flags=re.DOTALL)
    # Add get-task-allow if not present
    if '<key>get-task-allow</key>' not in c:
        c = c.replace('</dict>\n</plist>', '\t<key>get-task-allow</key>\n\t<true/>\n</dict>\n</plist>')
    with open(dst, 'w') as f:
        f.write(c)
    print(f'{name}: {os.path.getsize(src)} -> {os.path.getsize(dst)} bytes, stripped seatbelt, added get-task-allow')
