#!/usr/bin/env python3
"""扫一个 HAP 里有没有本机凭据 / 个人信息。

用法：python3 tools/apple-music/scan-hap-secrets.py <hap 路径> [--expect-clean]

检查项：
  ① DeepSeek 风格 key（sk- 开头的长串）
  ② Widevine WVD（base64 以 V1ZEAg 开头）
  ③ 本机绝对路径 /Users/<user>
  ④ Apple 的 media-user-token / 开发者 token（eyJ… 长 JWT）
"""
import sys, zipfile, re, os

PATTERNS = [
    ('AI key（sk- 开头）', re.compile(rb'sk-[0-9a-fA-F]{24,}')),
    ('Widevine WVD', re.compile(rb'V1ZEAg')),
    ('本机用户路径', re.compile(rb'/Users/[A-Za-z0-9._-]+')),
    ('JWT / Apple token', re.compile(rb'eyJ[A-Za-z0-9_-]{40,}')),
]


def scan(path):
    hits = []
    with zipfile.ZipFile(path) as z:
        for name in z.namelist():
            if name.endswith('/'):
                continue
            try:
                data = z.read(name)
            except Exception:
                continue
            for label, pat in PATTERNS:
                m = pat.search(data)
                if m:
                    hits.append((label, name, m.group(0)[:40].decode('latin-1')))
    return hits


def main():
    if len(sys.argv) < 2:
        print('usage: scan-hap-secrets.py <hap> [--expect-clean]')
        return 2
    path = sys.argv[1]
    expect_clean = '--expect-clean' in sys.argv
    if not os.path.exists(path):
        print('找不到包：' + path)
        return 2
    size = os.path.getsize(path)
    hits = scan(path)
    print('扫描 %s（%.1f MB）' % (os.path.basename(path), size / 1048576.0))
    if not hits:
        print('  结果：干净 —— 没有 key / WVD / 本机路径 / token')
        return 0
    seen = set()
    for label, name, sample in hits:
        key = (label, name)
        if key in seen:
            continue
        seen.add(key)
        print('  命中：%s  在 %s  （样例 %s）' % (label, name, sample))
    if expect_clean:
        print('  结果：不合格 —— 分发包里不该出现以上内容')
        return 1
    print('  结果：含以上内容（本机自用包属预期，别把它发出去）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
