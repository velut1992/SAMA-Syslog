#!/usr/bin/env python3
"""Render any Supra Markdown document to styled HTML.

generate_docs.py does this too, but only for the two installation guides, whose
stems are hard-coded. This is the general counterpart to md2docx.py, so runbooks
and reports can be published in the same house style without editing a script.

Usage:
    python3 scripts/md2html.py <input.md> <output.html> [--title T] [--subtitle S]
"""

import argparse
import os
import sys

import markdown

# Same palette and layout as generate_docs.py, so a runbook sitting next to an
# installation guide does not look like it came from somewhere else.
CSS = """
        @page { size: A4; margin: 20mm; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            line-height: 1.6; color: #333; max-width: 960px;
            margin: 0 auto; padding: 20px 40px; background: #fff;
        }
        h1 { color: #1a237e; border-bottom: 3px solid #1a237e; padding-bottom: 10px; font-size: 2em; }
        h2 {
            color: #283593; border-bottom: 2px solid #c5cae9; padding-bottom: 8px;
            margin-top: 40px; font-size: 1.5em; page-break-after: avoid;
        }
        h3 { color: #3949ab; margin-top: 25px; font-size: 1.2em; page-break-after: avoid; }
        table {
            border-collapse: collapse; width: 100%; margin: 15px 0;
            font-size: 0.9em; page-break-inside: avoid;
        }
        th { background-color: #1a237e; color: white; padding: 10px 12px; text-align: left; font-weight: 600; }
        td { padding: 8px 12px; border: 1px solid #ddd; }
        tr:nth-child(even) { background-color: #f5f5f5; }
        tr:hover { background-color: #e8eaf6; }
        code {
            background-color: #f5f5f5; padding: 2px 6px; border-radius: 3px;
            font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
            font-size: 0.9em; color: #c62828;
        }
        pre {
            background-color: #263238; color: #eeffff; padding: 16px 20px;
            border-radius: 6px; overflow-x: auto; font-size: 0.85em;
            line-height: 1.5; page-break-inside: avoid;
        }
        pre code { background: none; color: #eeffff; padding: 0; font-size: 1em; }
        blockquote {
            border-left: 4px solid #ff6f00; margin: 15px 0; padding: 10px 20px;
            background-color: #fff8e1; color: #e65100; font-weight: 500;
        }
        blockquote strong { color: #bf360c; }
        a { color: #1565c0; text-decoration: none; }
        a:hover { text-decoration: underline; }
        hr { border: none; border-top: 2px solid #e0e0e0; margin: 30px 0; }
        ul, ol { padding-left: 25px; }
        li { margin-bottom: 4px; }
        .header-bar {
            background: linear-gradient(135deg, #1a237e, #283593); color: white;
            padding: 30px 40px; margin: -20px -40px 30px -40px; text-align: center;
        }
        .header-bar h1 { color: white; border: none; margin: 0; font-size: 2.2em; }
        .header-bar p { color: #c5cae9; margin: 5px 0 0 0; font-size: 1.1em; }
        @media print {
            body { padding: 0; max-width: none; }
            .header-bar { margin: 0 0 30px 0; }
            pre { white-space: pre-wrap; word-wrap: break-word; }
            h2 { page-break-before: auto; }
        }
"""


def convert(input_path, output_path, title, subtitle):
    with open(input_path, "r", encoding="utf-8") as f:
        md_content = f.read()

    # nl2br matches generate_docs.py: the Supra docs rely on single newlines
    # rendering as line breaks inside notes and command blocks.
    html_body = markdown.markdown(
        md_content,
        extensions=["tables", "fenced_code", "codehilite", "toc", "nl2br"],
        extension_configs={
            "codehilite": {"css_class": "code"},
            "toc": {"permalink": False},
        },
    )

    if not title:
        title = os.path.splitext(os.path.basename(input_path))[0]

    header = f'<h1>{title}</h1>'
    if subtitle:
        header += f'\n        <p>{subtitle}</p>'

    html_full = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{title}</title>
    <style>{CSS}    </style>
</head>
<body>
    <div class="header-bar">
        {header}
    </div>
    {html_body}
</body>
</html>
"""

    with open(output_path, "w", encoding="utf-8") as f:
        f.write(html_full)
    return output_path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--title", default="")
    ap.add_argument("--subtitle", default="")
    args = ap.parse_args()

    out = convert(args.input, args.output, args.title, args.subtitle)
    print(f"HTML generated: {out}")


if __name__ == "__main__":
    sys.exit(main())
