import os

TPL = ('<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.0 Transitional//EN">'
       '<html><head><meta content="text/html; charset=utf-8" http-equiv="Content-Type"></meta>'
       '<link rel="stylesheet" type="text/css" href="v8help://service_book/service_style"></link>'
       '<meta name="GENERATOR" content="MSHTML 8.00.7601.17514"></meta>'
       '</head><body><span lang="RU">\r\n</span></body></html>')

n = 0
for d in os.listdir('unpack_cf/Report'):
    p = os.path.join('unpack_cf/Report', d)
    if not os.path.isdir(p):
        continue
    files = os.listdir(p)
    if any(f.startswith('Report.') and not f.endswith('.json') for f in files):
        continue
    open(os.path.join(p, 'Report.html'), 'w', encoding='utf-8-sig', newline='').write(TPL)
    n += 1
print('добавлено пустых Report.html:', n)
