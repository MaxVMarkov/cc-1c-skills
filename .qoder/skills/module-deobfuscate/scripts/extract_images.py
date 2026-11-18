"""Извлечение байткода (image) из контейнеров закрытых модулей 1С.

Формат Ext/<Модуль>.bin (платформа 8.3.20+): 16-байтный заголовок, далее блоки
[дескриптор][полезная нагрузка][выравнивание]. Дескриптор — 29 байт ASCII: три
8-значных hex-поля через пробел, пробел, CRLF. Первое поле — фактический размер
нагрузки, второе — выделенный (может быть с запасом), третье всегда 0x7fffffff.
Между блоками 2 байт мусора, поэтому нагрузкой считается
`raw[дескриптор+29 : +первое_поле]`, а не отрезок до следующего дескриптора —
иначе в хвост попадают байты выравнивания. Блоков 7 (иногда больше): индекс,
таблица имён, image (байткод), два служебных, заголовок `text` и последний блок —
исходный текст модуля в зашифрованном/сжатом виде.

Признак закрытого модуля — блок, начинающийся с UTF-8 BOM и `{1,`. Он есть
только у модулей: `Ext/*.bin` без `.bsl` бывают и у макетов, и у картинок.

    python extract_images.py <каталог-выгрузки> <каталог-image> <файл-манифеста>

Манифест: строки `<путь.image>|<путь.bsl>` в UTF-8 без BOM, по одной на модуль.
"""
import os
import re
import sys

BOM = b'\xef\xbb\xbf'
DESC = re.compile(rb'([0-9a-fA-F]{8}) ([0-9a-fA-F]{8}) ([0-9a-fA-F]{8}) \r\n')


def closed_bins(root):
    """Все Ext/*.bin без одноимённого .bsl рядом (модули и не только)."""
    result = []
    for dirpath, _, filenames in os.walk(root):
        if os.path.basename(dirpath).lower() != 'ext':
            continue
        for name in filenames:
            if not name.lower().endswith('.bin'):
                continue
            path = os.path.join(dirpath, name)
            if not os.path.exists(path[:-4] + '.bsl'):
                result.append(path)
    return sorted(result)


def image_of(raw):
    """Байткод модуля без BOM, либо None — если это не закрытый модуль."""
    for mark in DESC.finditer(raw):
        payload = raw[mark.end():mark.end() + int(mark.group(1), 16)]
        if payload.startswith(BOM + b'{1,'):
            return payload[len(BOM):]
    return None


def closed_modules(root):
    """[(путь, байткод)] по всем закрытым модулям выгрузки, отсортировано."""
    result = []
    for path in closed_bins(root):
        image = image_of(open(path, 'rb').read())
        if image is not None:
            result.append((path, image))
    return sorted(result)


def check(image):
    notes = []
    try:
        text = image.decode('utf-8')
    except UnicodeDecodeError as exc:
        return ['НЕ UTF-8: %s' % exc]
    if text.count('{') != text.count('}'):
        notes.append('число скобок не совпадает: {=%d }=%d (возможно, { внутри '
                     'строковой константы)' % (text.count('{'), text.count('}')))
    if not text.rstrip().endswith('}'):
        notes.append('не заканчивается на }')
    return notes


def main():
    root = os.path.abspath(sys.argv[1])
    img_dir = os.path.abspath(sys.argv[2])
    manifest = os.path.abspath(sys.argv[3])
    os.makedirs(img_dir, exist_ok=True)
    os.makedirs(os.path.dirname(manifest), exist_ok=True)

    report = []
    lines = []
    bad = 0
    for path, image in closed_modules(root):
        rel = os.path.relpath(path, root)
        notes = check(image)
        if notes:
            bad += 1
            report.append('ВНИМАНИЕ %s: %s' % (rel, '; '.join(notes)))
        flat = rel.replace(os.sep, '__').replace('/', '__')[:-4]
        img_path = os.path.join(img_dir, flat + '.image')
        bsl_path = os.path.join(img_dir, flat + '.bsl')
        open(img_path, 'wb').write(image)
        lines.append('%s|%s' % (img_path, bsl_path))
        report.append('%10d %s -> %s' % (len(image), rel, img_path))

    open(manifest, 'wb').write(('\r\n'.join(lines) + '\r\n').encode('utf-8'))
    report.append('МОДУЛЕЙ: %d, С ПРОБЛЕМАМИ: %d, МАНИФЕСТ: %s'
                  % (len(lines), bad, manifest))
    out = os.path.join(os.path.dirname(manifest), 'extract_report.txt')
    open(out, 'w', encoding='utf-8').write(os.linesep.join(report) + os.linesep)
    print('extracted=%d problems=%d report=%s' % (len(lines), bad, out))
    return 0 if lines else 1


if __name__ == '__main__':
    sys.exit(main())
