"""Exercise the CLI JSONL -> Anki TSV path with Python's independent CSV reader.

Run from the repository root after putting MoonBit on PATH:
    python scripts/verify_anki_tsv.py
"""
import csv
import io
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    card_ids = ['A\tB\nC', 'D"E\rF', '#comment-like', '卡片']
    with tempfile.TemporaryDirectory(prefix='recall-anki-') as directory:
        log = Path(directory) / 'reviews.jsonl'
        log.write_text(''.join(json.dumps({
            'card_id': card_id, 'reviewed_at': 0, 'due_at': 0,
            'grade': 3, 'elapsed_days': 0,
        }) + '\n' for card_id in card_ids), encoding='utf-8')
        output = subprocess.run([
            'moon', 'run', 'cmd/recall', '--warn-list', '-a', '--', 'replay',
            '--log', str(log), '--scheduler', 'fsrs', '--anki',
        ], check=True, stdout=subprocess.PIPE).stdout.decode('utf-8')
    # Read bytes before decoding so Python does not normalize CR inside fields.
    # Headers occupy four physical lines; CSV parsing keeps quoted newlines.
    lines = output.splitlines(keepends=True)
    assert lines[0].rstrip('\r\n') == '#separator:tab'
    assert lines[2].rstrip('\r\n') == '# scheduler: fsrs'
    assert len(lines[3].removeprefix('#columns:').rstrip('\r\n').split('\t')) == 8
    data = ''.join(lines[4:])
    rows = [row for row in csv.reader(io.StringIO(data), delimiter='\t') if row]
    assert len(rows) == len(card_ids), rows
    assert all(len(row) == 8 for row in rows), rows
    assert [row[0] for row in rows] == sorted(card_ids), rows
    print('CLI JSONL -> TSV -> Python CSV: 4 IDs preserved, 8 columns each, valid headers')


if __name__ == '__main__':
    main()
