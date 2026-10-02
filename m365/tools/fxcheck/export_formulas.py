import sys, json
import os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import build_powerapps as b
out = []
def walk(cs, screen, gal):
    for c in cs:
        (name, body), = c.items()
        isgal = body['Control'].startswith('Gallery')
        for k, v in body['Properties'].items():
            g0 = name if (isgal and k != 'Items') else gal
            out.append({'screen': screen, 'control': name, 'prop': k, 'formula': v[1:] if v.startswith('=') else v, 'gallery': g0})
        g = name if body['Control'].startswith('Gallery') else gal
        walk(body.get('Children') or [], screen, g)
walk(b.browse_screen(), 'scrBrowse', None)
walk(b.admin_screen(), 'scrAdmin', None)
out.append({'screen': 'App', 'control': 'App', 'prop': 'OnStart', 'formula': b.ON_START, 'gallery': None})
json.dump(out, open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'formulas.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print(len(out))
