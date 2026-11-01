"""Check static website assets, anchors, and translation coverage before deployment."""
from html.parser import HTMLParser
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1] / 'website'


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = []
        self.keys = set()
        self.links = []
        self.screenshots = set()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'id' in attrs:
            self.ids.append(attrs['id'])
        for field in ('data-i18n', 'data-i18n-aria', 'data-i18n-title'):
            if field in attrs:
                self.keys.add(attrs[field])
        for field in ('href', 'src'):
            if field in attrs:
                self.links.append(attrs[field])
        if 'data-screenshot' in attrs:
            self.screenshots.add(attrs['data-screenshot'])


def check():
    page = Page()
    page.feed((ROOT / 'index.html').read_text(encoding='utf-8'))
    errors = []
    if len(page.ids) != len(set(page.ids)):
        errors.append('Duplicate HTML IDs')
    for link in page.links:
        url = urlsplit(link)
        if url.scheme or url.netloc:
            if url.scheme not in ('https', 'mailto'):
                errors.append(f'Unexpected external URL: {link}')
            continue
        if url.path:
            path = (ROOT / unquote(url.path)).resolve()
            if ROOT not in path.parents or not path.is_file():
                errors.append(f'Missing or invalid local asset: {link}')
        elif url.fragment and url.fragment not in page.ids:
            errors.append(f'Missing anchor target: {link}')
    script = (ROOT / 'app.js').read_text(encoding='utf-8')
    for name in page.screenshots:
        for language in ('zh', 'en'):
            for theme in ('light', 'dark'):
                image = ROOT / 'assets' / f'{name}-{language}-{theme}.jpg'
                if not image.is_file():
                    errors.append(f'Missing screenshot: {image.name}')
                elif image.read_bytes()[:2] != b'\xff\xd8':
                    errors.append(f'Expected JPEG screenshot: {image.name}')
    for key in sorted(page.keys):
        if len(re.findall(r'\b' + re.escape(key) + r':\s*"', script)) != 2:
            errors.append(f'Expected a Chinese and English translation for: {key}')
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'Website checks passed: {len(page.keys)} translated fields, assets and anchors valid.')


if __name__ == '__main__':
    check()
