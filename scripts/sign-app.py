#!/usr/bin/env python3
"""Sign nested code inside-out. Ad hoc locally; Developer ID when configured."""
import os
from pathlib import Path
import subprocess

app = Path('dist/SimLaunch.app')
identity = os.environ.get('CODESIGN_IDENTITY', '-')
options = ['--options', 'runtime', '--timestamp'] if identity != '-' else []
# Re-sign Sparkle helpers with the same identity as the containing app.
frameworks = app / 'Contents/Frameworks'
if frameworks.exists():
    for path in sorted(frameworks.rglob('*')):
        if path.is_file() and not path.is_symlink():
            kind = subprocess.check_output(['file', '-b', str(path)], text=True)
            if 'Mach-O' in kind:
                subprocess.run(['codesign', '--force', '--sign', identity, *options, '--preserve-metadata=entitlements', str(path)], check=True)
    bundles = [p for p in frameworks.rglob('*') if p.is_dir() and not p.is_symlink() and p.suffix in ['.app', '.xpc', '.framework']]
    for path in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
        subprocess.run(['codesign', '--force', '--sign', identity, *options, '--preserve-metadata=entitlements', str(path)], check=True)
subprocess.run(['codesign', '--force', '--sign', identity, *options, str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
