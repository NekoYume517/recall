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
        }, ensure_ascii=False) + '\n' for card_id in card_ids), encoding='utf-8')
        output = subprocess.run([
            'moon', 'run', 'cmd/recall', '--warn-list', '-a', '--', 'replay',
            '--log', str(log), '--scheduler', 'fsrs', '--anki',
        ], check=True, stdout=subprocess.PIPE, encoding='utf-8').stdout
    # Headers occupy four physical lines; CSV parsing keeps quoted newlines.
    data = ''.join(output.splitlines(keepends=True)[4:])
    rows = [row for row in csv.reader(io.StringIO(data), delimiter='\t') if row]
    assert len(rows) == len(card_ids), rows
    assert all(len(row) == 8 for row in rows), rows
    assert [row[0] for row in rows] == sorted(card_ids), rows
    print('CLI JSONL -> TSV -> Python CSV: 4 IDs preserved, 8 columns each')


if __name__ == '__main__':
    main()
