#!/usr/bin/env python3
"""Generate HTML and PDF from the Supra SIEM Installation Guide markdown."""

import markdown
import os
import subprocess

BASE_DIR = "/home/velu/Hitachi"
MD_FILE = os.path.join(BASE_DIR, "Supra_SIEM_Installation_and_User_Guide.md")
HTML_FILE = os.path.join(BASE_DIR, "Supra_SIEM_Installation_and_User_Guide.html")
PDF_FILE = os.path.join(BASE_DIR, "Supra_SIEM_Installation_and_User_Guide.pdf")

# Read markdown
with open(MD_FILE, "r") as f:
    md_content = f.read()

# Convert to HTML with extensions
html_body = markdown.markdown(
    md_content,
    extensions=["tables", "fenced_code", "codehilite", "toc", "nl2br"],
    extension_configs={
        "codehilite": {"css_class": "code"},
        "toc": {"permalink": False},
    },
)

# Full HTML with professional styling
html_full = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Supra SIEM Platform - Installation and User Guide</title>
    <style>
        @page {{
            size: A4;
            margin: 20mm;
        }}
        body {{
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 960px;
            margin: 0 auto;
            padding: 20px 40px;
            background: #fff;
        }}
        h1 {{
            color: #1a237e;
            border-bottom: 3px solid #1a237e;
            padding-bottom: 10px;
            font-size: 2em;
        }}
        h2 {{
            color: #283593;
            border-bottom: 2px solid #c5cae9;
            padding-bottom: 8px;
            margin-top: 40px;
            font-size: 1.5em;
            page-break-after: avoid;
        }}
        h3 {{
            color: #3949ab;
            margin-top: 25px;
            font-size: 1.2em;
            page-break-after: avoid;
        }}
        table {{
            border-collapse: collapse;
            width: 100%;
            margin: 15px 0;
            font-size: 0.9em;
            page-break-inside: avoid;
        }}
        th {{
            background-color: #1a237e;
            color: white;
            padding: 10px 12px;
            text-align: left;
            font-weight: 600;
        }}
        td {{
            padding: 8px 12px;
            border: 1px solid #ddd;
        }}
        tr:nth-child(even) {{
            background-color: #f5f5f5;
        }}
        tr:hover {{
            background-color: #e8eaf6;
        }}
        code {{
            background-color: #f5f5f5;
            padding: 2px 6px;
            border-radius: 3px;
            font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
            font-size: 0.9em;
            color: #c62828;
        }}
        pre {{
            background-color: #263238;
            color: #eeffff;
            padding: 16px 20px;
            border-radius: 6px;
            overflow-x: auto;
            font-size: 0.85em;
            line-height: 1.5;
            page-break-inside: avoid;
        }}
        pre code {{
            background: none;
            color: #eeffff;
            padding: 0;
            font-size: 1em;
        }}
        blockquote {{
            border-left: 4px solid #ff6f00;
            margin: 15px 0;
            padding: 10px 20px;
            background-color: #fff8e1;
            color: #e65100;
            font-weight: 500;
        }}
        blockquote strong {{
            color: #bf360c;
        }}
        a {{
            color: #1565c0;
            text-decoration: none;
        }}
        a:hover {{
            text-decoration: underline;
        }}
        hr {{
            border: none;
            border-top: 2px solid #e0e0e0;
            margin: 30px 0;
        }}
        ul, ol {{
            padding-left: 25px;
        }}
        li {{
            margin-bottom: 4px;
        }}
        .header-bar {{
            background: linear-gradient(135deg, #1a237e, #283593);
            color: white;
            padding: 30px 40px;
            margin: -20px -40px 30px -40px;
            text-align: center;
        }}
        .header-bar h1 {{
            color: white;
            border: none;
            margin: 0;
            font-size: 2.2em;
        }}
        .header-bar p {{
            color: #c5cae9;
            margin: 5px 0 0 0;
            font-size: 1.1em;
        }}
        .toc {{
            background: #f5f5f5;
            border: 1px solid #e0e0e0;
            border-radius: 6px;
            padding: 20px 30px;
            margin: 20px 0;
        }}
        .toc a {{
            color: #1a237e;
        }}
        @media print {{
            body {{
                padding: 0;
                max-width: none;
            }}
            .header-bar {{
                margin: 0 0 30px 0;
            }}
            pre {{
                white-space: pre-wrap;
                word-wrap: break-word;
            }}
            h2 {{
                page-break-before: auto;
            }}
        }}
    </style>
</head>
<body>
    <div class="header-bar">
        <h1>Supra SIEM Platform</h1>
        <p>Installation and User Guide | Version 3.6.0 | March 2026</p>
    </div>
    {html_body}
</body>
</html>
"""

# Write HTML
with open(HTML_FILE, "w") as f:
    f.write(html_full)
print(f"HTML generated: {HTML_FILE}")

# Try to generate PDF
pdf_generated = False

# Method 1: wkhtmltopdf
try:
    subprocess.run(
        [
            "wkhtmltopdf",
            "--page-size", "A4",
            "--margin-top", "20mm",
            "--margin-bottom", "20mm",
            "--margin-left", "15mm",
            "--margin-right", "15mm",
            "--encoding", "UTF-8",
            "--enable-local-file-access",
            "--quiet",
            HTML_FILE,
            PDF_FILE,
        ],
        check=True,
        capture_output=True,
    )
    pdf_generated = True
    print(f"PDF generated: {PDF_FILE}")
except (FileNotFoundError, subprocess.CalledProcessError):
    pass

# Method 2: pandoc with LaTeX
if not pdf_generated:
    try:
        subprocess.run(
            [
                "pandoc",
                MD_FILE,
                "-o", PDF_FILE,
                "--pdf-engine=xelatex",
                "-V", "geometry:margin=1in",
                "-V", "fontsize=11pt",
            ],
            check=True,
            capture_output=True,
        )
        pdf_generated = True
        print(f"PDF generated: {PDF_FILE}")
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass

if not pdf_generated:
    print("")
    print("PDF generation requires one of these tools:")
    print("  sudo apt-get install -y wkhtmltopdf")
    print("  OR")
    print("  sudo apt-get install -y pandoc texlive-xetex")
    print("")
    print(f"Then run: python3 {__file__}")
    print("")
    print("Alternative: Open the HTML file in a browser and use Print > Save as PDF")
