"""Раскладка декомпилированных модулей в XML-выгрузку 1С.

Имя файла в каталоге декомпиляции — это путь .bin в выгрузке, где разделители
каталогов заменены на `__`. Кладём <Модуль>.bsl рядом с <Модуль>.bin и
переименовываем .bin в <Модуль>.bin<.backup>, иначе выгрузка перестаёт быть
однозначной (два представления одного модуля).

    python apply_bsl.py <каталог-выгрузки> <каталог-bsl> [<суффикс-бэкапа>]
"""
import os
import shutil
import sys


def main():
    root = os.path.abspath(sys.argv[1])
    bsl_dir = os.path.abspath(sys.argv[2])
    suffix = sys.argv[3] if len(sys.argv) > 3 else '.closed'
    report = []
    moved = 0
    missing = 0
    for name in sorted(os.listdir(bsl_dir)):
        if not name.endswith('.bsl'):
            continue
        rel = name[:-4].replace('__', os.sep) + '.bsl'
        target = os.path.join(root, rel)
        bin_path = target[:-4] + '.bin'
        if not os.path.isdir(os.path.dirname(target)):
            missing += 1
            report.append('НЕТ КАТАЛОГА %s' % rel)
            continue
        shutil.copyfile(os.path.join(bsl_dir, name), target)
        if os.path.exists(bin_path):
            os.replace(bin_path, bin_path + suffix)
            report.append('%s + %s -> %s' % (rel, os.path.basename(bin_path),
                                             os.path.basename(bin_path) + suffix))
        else:
            report.append('%s (bin уже отсутствует)' % rel)
        moved += 1
    report.append('РАЗОЛОЖЕНО: %d, ПРОПУЩЕНО: %d' % (moved, missing))
    out = os.path.join(bsl_dir, 'apply_report.txt')
    open(out, 'w', encoding='utf-8').write(os.linesep.join(report) + os.linesep)
    print('applied=%d skipped=%d report=%s' % (moved, missing, out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
