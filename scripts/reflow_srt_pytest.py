#!/usr/bin/env python3
import sys, re, os
from math import floor

def parse_time(tc):
    m = re.match(r"(\d{2}):(\d{2}):(\d{2}),(\d{1,3})", tc.strip())
    if not m:
        raise ValueError(f"Invalid timecode: {tc}")
    h,mn,s,ms = m.groups()
    return int(h)*3600 + int(mn)*60 + int(s) + int(ms)/1000.0

def fmt_time(sec):
    if sec < 0: sec = 0
    h = int(sec//3600)
    rem = sec - h*3600
    m = int(rem//60)
    s = int(rem - m*60)
    ms = int(round((sec - floor(sec))*1000))
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def read_srt(path):
    with open(path, 'r', encoding='utf-8') as f:
        raw = f.read()
    raw = raw.replace('\r\n','\n')
    blocks = [b.strip() for b in raw.split('\n\n') if b.strip()]
    cues = []
    for b in blocks:
        lines = b.split('\n')
        # find time line
        time_line = None
        if '-->' in lines[0]:
            time_line = lines[0]
            text_lines = lines[1:]
        elif len(lines) >= 2 and '-->' in lines[1]:
            time_line = lines[1]
            text_lines = lines[2:]
        else:
            continue
        times = [t.strip() for t in time_line.split('-->')]
        if len(times) != 2: continue
        start = parse_time(times[0]); end = parse_time(times[1])
        text = ' '.join([l.strip() for l in text_lines]).strip()
        cues.append({'start': start, 'end': end, 'duration': end-start, 'text': text})
    return cues


def tokenize(text):
    if not text: return []
    return re.split(r"\s+", text)


def reflow_lines(words, max_chars, max_words):
    lines = []
    cur = []
    for w in words:
        cur_len = len(' '.join(cur)) if cur else 0
        next_len = (cur_len + 1 + len(w)) if cur else len(w)
        if (cur and next_len > max_chars) or (len(cur) >= max_words):
            lines.append(' '.join(cur))
            cur = [w]
        else:
            cur.append(w)
    if cur:
        lines.append(' '.join(cur))
    return lines


def split_cue_by_words(cue, max_words, min_duration):
    words = tokenize(cue['text'])
    if len(words) <= max_words and cue['duration'] <= max_seconds:
        return [cue]
    chunks = [words[i:i+max_words] for i in range(0, len(words), max_words)]
    total = len(words)
    total_dur = cue['duration']
    out = []
    pos = cue['start']
    for ch in chunks:
        portion = len(ch)/total
        dur = total_dur * portion
        if dur < min_duration:
            dur = min_duration
        start = pos
        end = pos + dur
        out.append({'start': start, 'end': end, 'duration': end-start, 'text': ' '.join(ch)})
        pos = end
    if out:
        out[-1]['end'] = cue['end']
        out[-1]['duration'] = out[-1]['end'] - out[-1]['start']
    return out


def merge_cues(cues, min_duration, pause_ms):
    out = []
    for c in cues:
        if not out:
            out.append(c)
            continue
        prev = out[-1]
        gap = c['start'] - prev['end']
        if prev['duration'] < min_duration or gap < (pause_ms/1000.0):
            merged = {'start': prev['start'], 'end': c['end'], 'duration': c['end']-prev['start'], 'text': (prev['text']+' '+c['text']).strip()}
            out[-1] = merged
        else:
            out.append(c)
    return out


def normalize_and_reflow(cues, max_chars, max_words, max_seconds, min_duration, pause_ms):
    expanded = []
    for cue in cues:
        words = tokenize(cue['text'])
        if len(words) > max_words or cue['duration'] > max_seconds:
            splits = split_cue_by_words(cue, max_words, min_duration)
            expanded.extend(splits)
        else:
            expanded.append(cue)
    merged = merge_cues(expanded, min_duration, pause_ms)
    final = []
    for c in merged:
        w = tokenize(c['text'])
        lines = reflow_lines(w, max_chars, max_words)
        c['lines'] = lines
        final.append(c)
    return final

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Usage: reflow_srt_pytest.py <input.srt>')
        sys.exit(1)
    inp = sys.argv[1]
    if not os.path.exists(inp):
        print('Input not found:', inp); sys.exit(2)
    # defaults
    max_chars = 80
    max_words = 12
    global max_seconds
    max_seconds = 4.0
    min_duration = 0.4
    pause_ms = 300

    cues = read_srt(inp)
    print(f'Read {len(cues)} cues')
    out = normalize_and_reflow(cues, max_chars, max_words, max_seconds, min_duration, pause_ms)
    out_path = os.path.splitext(inp)[0] + '.reflow.srt'
    with open(out_path, 'w', encoding='utf-8') as f:
        idx = 1
        for c in out:
            f.write(str(idx) + '\n')
            f.write(f"{fmt_time(c['start'])} --> {fmt_time(c['end'])}\n")
            for l in c['lines']:
                f.write(l + '\n')
            f.write('\n')
            idx += 1
    print('Wrote', out_path)
