"""Прикрутить пакетный блок к обработке-декомпилятору Ассемблер.

Ассемблер (https://github.com/ProhorP/1C-inversion) декомпилирует байткод в BSL
чистым кодом 1С, но управляемая форма требует человека: кнопка «ОткрытьФайл»,
потом «Декомпиляция». Пакетный блок (assets/batch-block.bsl) добавляет обработчик
OnOpen, который читает манифест, прогоняет все модули и завершает сеанс, поэтому
обработку можно запускать из командной строки через /Execute.

    python patch_editor_form.py <выгрузка-обработки> <блок.bsl> [имя-формы]

Объявления Перем из блока ставятся в начало модуля: платформа не принимает их в
середине. Если блок в модуле уже есть (по строке-маркеру), он заменяется целиком,
так что патч можно применять повторно после правки assets/batch-block.bsl.

После патча обработку нужно пересобрать: /epf-build.
"""
import os
import re
import sys

MARKER = '// ==== пакетная декомпиляция закрытых модулей'
PROC = re.compile(r'^(Процедура|Функция|Function|Procedure)\b')
DECL = re.compile(r'^Перем\b')
DIRECTIVE = re.compile(r'^&\w+$')


def load(path):
    raw = open(path, 'rb').read()
    bom = raw[:3] == b'\xef\xbb\xbf'
    if bom:
        raw = raw[3:]
    return raw.decode('utf-8'), bom


def save(path, text, bom):
    out = text.encode('utf-8')
    open(path, 'wb').write((b'\xef\xbb\xbf' + out) if bom else out)


def eol(text):
    return '\r\n' if '\r\n' in text else '\n'


def split_decls(block, sep):
    """Вынуть объявления Перем (со стоящей перед ними директивой) из блока."""
    lines = block.split(sep)
    decls = []
    kept = []
    for line in lines:
        if DECL.match(line):
            if kept and DIRECTIVE.match(kept[-1].strip()):
                decls.append(kept.pop())
            decls.append(line)
            continue
        kept.append(line)
    return decls, sep.join(kept).strip(sep)


def inject_decls(lines, decls, sep):
    """Вставить decls сразу после последнего Перем в шапке модуля."""
    last = None
    for i, line in enumerate(lines):
        if PROC.match(line):
            break
        if DECL.match(line):
            last = i
    if last is None:
        return decls + lines, None
    have = set()
    for line in lines[:last + 1]:
        m = re.match(r'^Перем\s+(\w+)', line)
        if m:
            have.add(m.group(1).lower())
    add = []
    i = 0
    while i < len(decls):
        m = re.match(r'^Перем\s+(\w+)', decls[i])
        if m and m.group(1).lower() in have:
            if add and DIRECTIVE.match(add[-1].strip()):
                add.pop()
            i += 1
            continue
        add.append(decls[i])
        i += 1
    return lines[:last + 1] + add + lines[last + 1:], last


def main():
    dump = os.path.abspath(sys.argv[1])
    block_path = os.path.abspath(sys.argv[2])
    form = sys.argv[3] if len(sys.argv) > 3 else 'Редактор'

    mod = None
    # Форма лежит так: <Объект>/Forms/<ИмяФормы>/Ext/Form.xml и .../Ext/Form/Module.bsl
    for dirpath, _, filenames in os.walk(dump):
        if os.path.basename(dirpath).lower() != 'ext' or 'Form.xml' not in filenames:
            continue
        if os.path.basename(os.path.dirname(dirpath)) != form:
            continue
        inner = os.path.join(dirpath, 'Form')
        if not os.path.isdir(inner) or 'Module.bsl' not in os.listdir(inner):
            continue
        mod = os.path.join(inner, 'Module.bsl')
        fx = os.path.join(dirpath, 'Form.xml')
    if mod is None:
        print('форма %s не найдена в %s' % (form, dump))
        return 1

    text, mbom = load(mod)
    sep = eol(text)
    lines = text.split(sep)
    marks = [i for i, l in enumerate(lines) if l.startswith(MARKER)]
    if marks:
        head = lines[:marks[0]]
        action = 'блок обновлён'
    else:
        head = lines
        action = 'блок добавлен'

    block, _ = load(block_path)
    block = block.replace(eol(block), sep)
    decls, body = split_decls(block, sep)
    head, after = inject_decls(head, decls, sep)
    if decls and after is None:
        print('в шапке модуля нет ни одного Перем — объявления некуда ставить')
        return 1
    out = sep.join(head).rstrip(' \t' + sep) + sep * 2 + body + sep
    save(mod, out, mbom)

    xml, xbom = load(fx)
    xsep = eol(xml)
    if '<Event name="OnOpen">' in xml:
        print('OnOpen уже зарегистрирован')
    else:
        xml, n = re.subn('<Events>',
                         '<Events>' + xsep + chr(9) * 2 + '<Event name="OnOpen">ПриОткрытии</Event>',
                         xml, count=1)
        if n != 1:
            print('блок <Events> не найден в Form.xml')
            return 1
        save(fx, xml, xbom)

    print('%s: строк %d (объявлений перенесено %d), байт %d'
          % (action, out.count('\n') + 1, len(decls), len(out.encode('utf-8'))))
    return 0


if __name__ == '__main__':
    sys.exit(main())
