"""Структурная проверка декомпилированных модулей.

Считает объявления процедур/функций и концы по началу строки; расхождение
означает обрыв тела модуля. Кодировка и наличие BOM — заодно.

    python check_bsl.py <каталог-bsl>
"""
import os
import re
import sys

d = os.path.abspath(sys.argv[1])
rep = []
DEC = re.compile(r'^(?:&\w+\s*)?(Процедура|Функция)\s', re.I)
END = re.compile(r'^Конец(Процедуры|Функции)\b', re.I)
ok = 0
for name in sorted(os.listdir(d)):
    if not name.endswith('.bsl'):
        continue
    raw = open(os.path.join(d, name), 'rb').read()
    bom = raw[:3] == b'\xef\xbb\xbf'
    try:
        text = raw[3:].decode('utf-8') if bom else raw.decode('utf-8')
    except UnicodeDecodeError as exc:
        rep.append('НЕ UTF-8 %s: %s' % (name, exc))
        continue
    dec = len([l for l in text.split('\n') if DEC.match(l.strip())])
    end = len([l for l in text.split('\n') if END.match(l.strip())])
    flag = '' if dec == end else ' <== РАЗБИР'
    if dec == end:
        ok += 1
    rep.append('%9d bom=%s объявлений=%4d концов=%4d %s%s'
               % (len(raw), bom, dec, end, name, flag))
rep.append('СОВПАЛО: %d' % ok)
open(os.path.join(d, 'check_report.txt'), 'w', encoding='utf-8').write(
    os.linesep.join(rep) + os.linesep)
print('checked=%d matched=%d' % (len([n for n in os.listdir(d) if n.endswith('.bsl')]), ok))
