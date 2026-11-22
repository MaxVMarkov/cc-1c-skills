import json, os

GOOD = [["5", "1", "\"ru\"", ["#base64:"], "0"]]


def bad(help_):
    return not help_ or len(help_[0]) <= 2 or not isinstance(help_[0][3], list)


n = 0
for d in os.listdir('unpack_cf/Report'):
    p = os.path.join('unpack_cf/Report', d)
    j = os.path.join(p, 'Report.json')
    if not os.path.isfile(j):
        continue
    bom = open(j, 'rb').read(3) == b'\xef\xbb\xbf'
    h = json.load(open(j, encoding='utf-8-sig'))
    if not bad(h.get('help')) and not bom:
        continue
    if bad(h.get('help')):
        h['help'] = GOOD
    open(j, 'w', encoding='utf-8', newline='\n').write(json.dumps(h, ensure_ascii=False, indent=2))
    n += 1
print('нормализовано help:', n)
