import sys

def unflat(src, dst):
    t = open(src, encoding='utf-8-sig').read()
    out = []
    q = False
    i = 0
    changed = 0
    while i < len(t):
        c = t[i]
        if c == '"':
            if t[i:i + 2] == '""':
                out.append('""')
                i += 2
                continue
            q = not q
            out.append(c)
            i += 1
            continue
        if c == '|' and q:
            prev = t[i - 1]
            nxt = t[i + 1] if i + 1 < len(t) else ''
            if prev == '"' and nxt == '"':
                out.append(c)
            else:
                out.append('\r\n|')
                changed += 1
            i += 1
            continue
        out.append(c)
        i += 1
    open(dst, 'w', encoding='utf-8-sig', newline='').write(''.join(out))
    print('unflat', dst, changed)

for src, dst in [(sys.argv[1], sys.argv[2])]:
    unflat(src, dst)
