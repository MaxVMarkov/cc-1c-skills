import re, sys

TRY = re.compile(r'(?i)^\s*попытка\b')
EXCEPT = re.compile(r'(?i)^\s*исключение\b')
END_TRY = re.compile(r'(?i)^\s*конецпопытки\b')
END_PROC = re.compile(r'(?i)^\s*конец(процедуры|функции)\b')
ENDIF = re.compile(r'(?i)^\s*конецесли\b')


def indent(line):
    return len(line) - len(line.lstrip('\t '))


def fix(src, dst):
    lines = open(src, encoding='utf-8-sig').read().split('\n')
    moved = 0
    i = 0
    while i < len(lines):
        if not TRY.match(lines[i]):
            i += 1
            continue
        ind = indent(lines[i])
        kp = exc = None
        body_end = None
        j = i + 1
        while j < len(lines):
            l = lines[j]
            if END_PROC.match(l):
                body_end = j
                break
            if TRY.match(l) and indent(l) <= ind:
                body_end = j
                break
            if ENDIF.match(l) and indent(l) <= ind:
                body_end = j
                break
            if EXCEPT.match(l):
                exc = j
                break
            if END_TRY.match(l):
                kp = j
                body_end = j
                break
            if l.strip() and indent(l) <= ind:
                body_end = j
                break
            j += 1
        if body_end is None:
            body_end = len(lines)
        if exc is None and kp is None:
            j2 = body_end
            while j2 < len(lines) and not END_PROC.match(lines[j2]):
                if EXCEPT.match(lines[j2]):
                    exc = j2
                    break
                if TRY.match(lines[j2]) and indent(lines[j2]) <= ind:
                    break
                if ENDIF.match(lines[j2]) and indent(lines[j2]) <= ind:
                    break
                j2 += 1
        if exc is None and kp is not None:
            j2 = kp + 1
            while j2 < len(lines) and not END_PROC.match(lines[j2]):
                if EXCEPT.match(lines[j2]):
                    exc = j2
                    break
                if TRY.match(lines[j2]) and indent(lines[j2]) <= ind:
                    break
                if ENDIF.match(lines[j2]) and indent(lines[j2]) <= ind:
                    break
                j2 += 1
        moved_tail = False
        if exc is None and kp is not None:
            q = kp + 1
            tail_end = None
            while q < len(lines):
                if END_PROC.match(lines[q]):
                    tail_end = q
                    break
                q += 1
            if tail_end is not None:
                q = tail_end - 1
                pos = []
                while q > i:
                    if EXCEPT.match(lines[q]) and indent(lines[q]) == ind:
                        pos.append(q)
                        q -= 1
                        continue
                    if not lines[q].strip():
                        q -= 1
                        continue
                    break
                if pos:
                    exc = pos[-1]
                    moved_tail = True
        if moved_tail:
            del lines[exc]
            del lines[kp]
            lines.insert(kp, ' ' * ind + 'КонецПопытки;')
            lines.insert(kp, ' ' * ind + 'Исключение')
            moved += 1
            i += 1
            continue
        if exc is None:
            if kp is not None:
                del lines[kp]
            lines.insert(body_end, ' ' * ind + 'КонецПопытки;')
            lines.insert(body_end, ' ' * ind + 'Исключение')
            moved += 1
            i += 1
            continue
        kp2 = None
        exc_end = None
        exc_ind = indent(lines[exc])
        j = exc + 1
        while j < len(lines):
            l = lines[j]
            if END_PROC.match(l):
                exc_end = j
                break
            if END_TRY.match(l):
                if indent(l) <= exc_ind:
                    kp2 = j
                    break
                del lines[j]
                continue
            if l.strip() and indent(l) <= exc_ind:
                exc_end = j
                break
            j += 1
        if exc_end is None:
            exc_end = len(lines)
        if kp is not None and kp < exc:
            del lines[kp]
            exc -= 1
            exc_end -= 1
            kp = None
        if kp2 is None:
            lines.insert(exc_end, ' ' * ind + 'КонецПопытки;')
            moved += 1
        i += 1
    stack = []
    i = 0
    while i < len(lines):
        w = lines[i].lstrip('	 ').lower()
        if TRY.match(w):
            stack.append(i)
            i += 1
            continue
        if END_TRY.match(w):
            if stack:
                stack.pop()
            i += 1
            continue
        if END_PROC.match(w):
            stack = []
            i += 1
            continue
        if EXCEPT.match(w) and not stack:
            exc_ind = indent(lines[i])
            del lines[i]
            moved += 1
            j = i
            while j < len(lines):
                l = lines[j]
                if END_PROC.match(l):
                    break
                if l.strip() and indent(l) <= exc_ind:
                    break
                del lines[j]
            continue
        i += 1
    data = '\n'.join(lines)
    open(dst, 'w', encoding='utf-8-sig', newline='').write(data)
    print('fixed', dst, 'правок:', moved)


for src, dst in [(sys.argv[1], sys.argv[2])]:
    fix(src, dst)
