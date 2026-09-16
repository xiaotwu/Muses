#!/usr/bin/env python3
"""Refresh Traditional Chinese copy using macOS ICU, preserving interpolated user data.

Static copy lives in a reviewable JSON catalog. Interpolated copy receives an
explicit zhHant argument because runtime string conversion could alter song names.
Run with the project's Swift toolchain installed; no third-party dependencies.
"""
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def string_end(text, start):
    i = start + 1
    while i < len(text):
        if text.startswith('\\(', i):
            i = interpolation_end(text, i + 2)
        elif text[i] == '\\':
            i += 2
        elif text[i] == '"':
            return i + 1
        else:
            i += 1
    raise ValueError('Unclosed string')


def interpolation_end(text, start):
    depth, i = 1, start
    while i < len(text):
        if text[i] == '"':
            i = string_end(text, i)
            continue
        if text[i] == '(':
            depth += 1
        if text[i] == ')':
            depth -= 1
            if not depth:
                return i + 1
        i += 1
    raise ValueError('Unclosed interpolation')


def chunks(literal):
    parts, i, start = [], 0, 0
    while i < len(literal):
        if literal.startswith('\\(', i):
            parts.append((False, literal[start:i]))
            end = interpolation_end(literal, i + 2)
            parts.append((True, literal[i:end]))
            i = start = end
        elif literal[i] == '\\':
            i += 2
        else:
            i += 1
    parts.append((False, literal[start:]))
    return parts


records, terms = [], set()
for path in sorted((ROOT / 'Sources/Muses').rglob('*.swift')):
    source = path.read_text()
    # Table-driven labels pass `tr(en, zh)` rather than literal arguments.
    for match in re.finditer(r'\bzh(?:Hans)?:\s*"', source):
        try:
            start = match.end() - 1
            end = string_end(source, start)
            literal = source[start + 1:end - 1]
            if '\\(' not in literal:
                terms.add(literal)
                records.append((path, end, literal, [(False, literal)], False))
        except ValueError:
            continue
    for match in re.finditer(r'\btr\(\s*"', source):
        first = match.end() - 1
        try:
            first_end = string_end(source, first)
            second_match = re.match(r'\s*,\s*"', source[first_end:])
            if not second_match:
                continue
            second = first_end + second_match.end() - 1
            end = string_end(source, second)
            literal = source[second + 1:end - 1]
            parts = chunks(literal)
            for dynamic, part in parts:
                if not dynamic:
                    terms.add(part)
            records.append((path, end, literal, parts, source[end:].lstrip().startswith(')')))
        except ValueError:
            continue

# Convert literal segments only; the replacement list chooses macOS terminology.
swift = r'''
import Foundation
let data = FileHandle.standardInput.readDataToEndOfFile()
let strings = try JSONDecoder().decode([String].self, from: data)
let replacements = [
    ("设置", "設定"), ("软件", "軟體"), ("硬件", "硬體"), ("默认", "預設"),
    ("文件", "檔案"), ("文件夹", "資料夾"), ("信息", "資訊"), ("视频", "影片"),
    ("音频", "音訊"), ("网络", "網路"), ("鼠标", "滑鼠"), ("账号", "帳號"),
    ("缓存", "快取"), ("队列", "佇列"), ("曲目", "曲目"), ("歌词", "歌詞"),
    ("加载", "載入"), ("链接", "連結"), ("数据库", "資料庫"), ("搜索", "搜尋"),
    ("刷新", "重新整理"), ("后台", "背景"), ("登录", "登入"), ("注销", "登出"),
    ("内存", "記憶體"), ("退出", "結束"), ("菜单", "選單"), ("磁盘", "磁碟"),
    ("应用", "應用程式"), ("剪贴板", "剪貼簿"), ("书签", "書籤"), ("收藏", "喜愛項目")
].sorted { $0.0.count > $1.0.count }
var result: [String: String] = [:]
for source in strings {
    var value = source
    for (from, to) in replacements { value = value.replacingOccurrences(of: from, with: to) }
    result[source] = value.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? value
}
let output = try JSONEncoder().encode(result)
FileHandle.standardOutput.write(output)
'''
import tempfile
with tempfile.TemporaryDirectory(prefix='muses-l10n-') as directory:
    script = Path(directory) / 'convert.swift'
    script.write_text(swift)
    result = subprocess.run(['swift', str(script)], input=json.dumps(sorted(terms)).encode(),
                            stdout=subprocess.PIPE, check=True)
converted = json.loads(result.stdout)
catalog, edits = {}, {}
for path, end, literal, parts, can_insert in records:
    value = ''.join(part if dynamic else converted[part] for dynamic, part in parts)
    if any(dynamic for dynamic, _ in parts):
        if can_insert:
            edits.setdefault(path, []).append((end, ', zhHant: "' + value + '"'))
    else:
        try:
            catalog[json.loads('"' + literal + '"')] = json.loads('"' + value + '"')
        except json.JSONDecodeError:
            pass
# Hand-reviewed overrides take precedence over the mechanically converted seed.
catalog.update({
    '设置': '設定', '通用': '一般', '跟随系统': '跟隨系統', '收藏': '喜愛',
    '取消收藏': '取消喜愛', '已收藏': '已喜愛', '新建歌单…': '新增播放列表…',
    '歌单': '播放列表', '全部歌单': '所有播放列表', '播放与音质': '播放與音質',
    '外观与桌面': '外觀與桌面', '账号与内容': '帳號與內容',
    '歌词与智能': '歌詞與智慧功能', '关于与帮助': '關於與輔助說明',
    '帮助与隐私': '輔助說明與隱私權', '退出登录': '登出',
})
for path, insertions in edits.items():
    source = path.read_text()
    for position, insertion in sorted(set(insertions), reverse=True):
        source = source[:position] + insertion + source[position:]
    path.write_text(source)
target = ROOT / 'Sources/Muses/Resources/Localization/zh-Hant.json'
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
print(f'{len(catalog)} catalog entries; {sum(map(len, edits.values()))} interpolated strings localized')
