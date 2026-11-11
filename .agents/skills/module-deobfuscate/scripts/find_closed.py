"""Поиск закрытых модулей в XML-выгрузке конфигурации/обработки 1С.

Кандидат — Ext/<ИмяМодуля>.bin без одноимённого <ИмяМодуля>.bsl рядом, но таких
файлов в выгрузке больше, чем модулей: так же выглядят макеты и картинки.
Настоящий закрытый модуль отличает наличие image-блока (см. extract_images.py).

    python find_closed.py <каталог-выгрузки> [<файл-отчёта>]
"""
import os
import sys

from extract_images import closed_bins, closed_modules


def main():
    root = os.path.abspath(sys.argv[1])
    out = (open(sys.argv[2], 'w', encoding='utf-8')
           if len(sys.argv) > 2 else sys.stdout)
    found = closed_modules(root)
    images = {os.path.normcase(path) for path, _ in found}
    others = [path for path in closed_bins(root)
              if os.path.normcase(path) not in images]

    for path, image in found:
        out.write('%10d %10d %s\n' % (os.path.getsize(path), len(image),
                                      os.path.relpath(path, root)))
    out.write('ЗАКРЫТЫХ МОДУЛЕЙ: %d\n' % len(found))
    out.write('прочих .bin без .bsl (макеты, картинки): %d\n' % len(others))
    for path in others:
        out.write('           %10d %s\n' % (os.path.getsize(path),
                                            os.path.relpath(path, root)))
    if len(sys.argv) > 2:
        out.close()
    return 0 if found else 1


if __name__ == '__main__':
    sys.exit(main())
