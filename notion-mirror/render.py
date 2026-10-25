#!/usr/bin/env python3
"""Render a Notion snapshot into a static, read-only HTML mirror.

Inputs (snapshot/):
  - <page-id>.json   MCP notion-fetch output, OR pull_notion.py normalized
                     output {"title": ..., "last_edited": ..., "content": ...}
  - costs-rows.json  MCP notion-query-data-sources output, OR pull output
                     {"rows": [{"Name":..., "Priority":..., ...}, ...]}
Output: site/ (index.html, one .html per page, costs table, search.json)

Usage:  python3 render.py [--snapshot snapshot] [--out site]
No third-party dependencies. Safe to run offline: output is plain files.
"""
import argparse, html, json, re, sys
from datetime import datetime, timezone
from pathlib import Path

# Core pages, in hub order. Add pages here to include them in the mirror.
PAGES = [
    ("391762e3-6894-81db-a2d8-f3ed4e621232", "refit-hq"),
    ("391762e3-6894-812b-b6a1-eb47a70b364a", "checklist"),
    ("391762e3-6894-812d-b139-e473a66255cf", "costs"),
    ("391762e3-6894-8154-b5be-d7832aecf0b6", "systems"),
]

CSS = """
body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:860px;
margin:0 auto;padding:1.2rem 1.4rem 3rem;line-height:1.6;color:#1c2430;background:#fdfdfb}
a{color:#0b4f7c} h1{font-size:1.9rem;line-height:1.25} h2{margin-top:2rem}
.banner{background:#fff3cd;border:1px solid #e6c87a;border-radius:10px;padding:.7rem 1rem;
margin:1rem 0;font-size:.95rem}
.banner b{color:#6b4e00}
nav{background:#eef4f8;border-radius:10px;padding:.8rem 1rem;margin:1rem 0}
nav a{margin-right:1rem;white-space:nowrap}
.callout{border-left:4px solid #2f7fb8;background:#eef4f8;border-radius:0 8px 8px 0;
padding:.7rem 1rem;margin:1rem 0}
.columns{display:grid;grid-template-columns:1fr 1fr;gap:1.5rem}
@media(max-width:650px){.columns{grid-template-columns:1fr}}
table{border-collapse:collapse;width:100%;font-size:.92rem;margin:1rem 0}
th,td{border:1px solid #c9d3dc;padding:.4rem .55rem;text-align:left;vertical-align:top}
th{background:#eef4f8} tr:nth-child(even) td{background:#f7f9fb}
.totals{background:#eef4f8;border-radius:10px;padding:.8rem 1rem}
code{background:#eef0f2;padding:.1rem .3rem;border-radius:4px}
footer{margin-top:3rem;color:#66707a;font-size:.85rem;border-top:1px solid #ddd;padding-top:1rem}
.searchbox{width:100%;padding:.6rem;font-size:1rem;border:1px solid #b9c6d0;border-radius:8px}
.result{border-bottom:1px solid #e3e8ec;padding:.5rem 0}
"""

def esc(s):
    return html.escape(s, quote=False)

def inline(text):
    """Inline markdown-ish markup -> HTML. Order matters: escape first,
    then restore the tags Notion's fetch format already emits (<b>, <i>)."""
    out = esc(text)
    out = out.replace("&lt;b&gt;", "<b>").replace("&lt;/b&gt;", "</b>")
    out = out.replace("&lt;i&gt;", "<i>").replace("&lt;/i&gt;", "</i>")
    out = out.replace("&lt;br /&gt;", "<br>").replace("&lt;br&gt;", "<br>")
    # markdown links [text](url)
    out = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', out)
    # un-escape literal characters Notion writes escaped (\$, \~)
    out = out.replace("\\$", "$").replace("\\~", "~")
    return out

def strip_tags(text):
    t = re.sub(r"<[^>]+>", " ", text)
    t = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", t)
    return re.sub(r"\s+", " ", t).strip()

def convert(content):
    """Convert Notion fetch markdown-ish text to HTML body fragments."""
    # Keep only the <content>...</content> section when present.
    m = re.search(r"<content>(.*)</content>", content, re.S)
    body = m.group(1) if m else content
    # Drop the fetch header line if it survived.
    body = re.sub(r"^Here is the result of .*?:\n", "", body)
    # Linked pages / databases at the end of a page become link cards.
    def page_link(mo):
        url = mo.group(1)
        title = strip_tags(mo.group(2)).strip() or url
        return f'<p>📄 <a href="{esc(url)}">{esc(title)}</a> <span style="color:#66707a">(open in Notion)</span></p>'
    body = re.sub(r'<page url="([^"]+)">\s*(.*?)\s*</page>', page_link, body, flags=re.S)
    body = re.sub(r'<database[^>]*>\s*(.*?)\s*</database>',
                  r'<p>🗃️ Database: \1 (rows are rendered as a table below where available)</p>', body, flags=re.S)
    # Callouts and columns.
    body = re.sub(r'<callout[^>]*>(.*?)</callout>',
                  r'<div class="callout">\1</div>', body, flags=re.S)
    body = body.replace("<columns>", '<div class="columns">').replace("</columns>", "</div>")
    body = body.replace("<column>", "<div>").replace("</column>", "</div>")
    # Anything else tag-like that is structural metadata: drop, keep text.
    body = re.sub(r"<(ancestor-path|properties|iconMetadata|mention|span|p|li|ul)[^>]*>", "", body)
    body = re.sub(r"</(ancestor-path|properties|iconMetadata|mention|span|p|li|ul)>", "", body)

    out, para, lst, table = [], [], [], []
    def flush_para():
        if para:
            out.append("<p>" + " ".join(inline(p) for p in para) + "</p>"); para.clear()
    def flush_list():
        if lst:
            items = "".join(f"<li>{inline(i)}</li>" for i in lst)
            out.append(f"<ul>{items}</ul>"); lst.clear()
    def flush_table():
        if table:
            rows = []
            for i, row in enumerate(table):
                cells = [c.strip() for c in row.strip().strip("|").split("|")]
                tag = "th" if i == 0 else "td"
                rows.append("<tr>" + "".join(f"<{tag}>{inline(c)}</{tag}>" for c in cells) + "</tr>")
            out.append("<table>" + "".join(rows) + "</table>"); table.clear()

    for raw in body.split("\n"):
        line = raw.strip()
        if not line:
            flush_para(); flush_list(); flush_table(); continue
        if line.startswith("<div") or line.startswith("</div") or line.startswith('<div class="callout"') or line == "</div>":
            flush_para(); flush_list(); flush_table(); out.append(line); continue
        if line.startswith("---"):
            flush_para(); flush_list(); flush_table(); out.append("<hr>"); continue
        if line.startswith("### "):
            flush_para(); flush_list(); flush_table(); out.append(f"<h3>{inline(line[4:])}</h3>"); continue
        if line.startswith("## "):
            flush_para(); flush_list(); flush_table(); out.append(f"<h2>{inline(line[3:])}</h2>"); continue
        if line.startswith("# "):
            flush_para(); flush_list(); flush_table(); out.append(f"<h1>{inline(line[2:])}</h1>"); continue
        if line.startswith("|"):
            flush_para(); flush_list()
            if set(line.replace("|", "").strip()) <= set("-: "):
                continue  # separator row
            table.append(line); continue
        if line.startswith("- [x] ") or line.startswith("- [ ] "):
            flush_para(); flush_table()
            done = line.startswith("- [x] ")
            lst.append(("✅ " if done else "☐ ") + line[6:]); continue
        if line.startswith("- "):
            flush_para(); flush_table(); lst.append(line[2:]); continue
        if line.startswith("• "):
            flush_para(); flush_table(); lst.append(line[2:]); continue
        flush_list(); flush_table(); para.append(line)
    flush_para(); flush_list(); flush_table()
    return "\n".join(out)

def money(v):
    return f"${v:,.0f}" if isinstance(v, (int, float)) else "—"

def costs_table(rows):
    order = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
    rows = sorted(rows, key=lambda r: (order.get(r.get("Priority"), 9), r.get("Name", "")))
    totals = {}
    for r in rows:
        t = totals.setdefault(r.get("Priority"), [0, 0, 0])
        t[0] += r.get("Estimate Low ($)") or 0
        t[1] += r.get("Estimate High ($)") or 0
        t[2] += 1
    parts = ['<div class="totals"><b>Totals (from live rows, not the page snapshot):</b><ul>']
    for p in sorted(totals, key=lambda k: order.get(k, 9)):
        lo, hi, n = totals[p]
        parts.append(f"<li>{p}: {money(lo)} – {money(hi)} ({n} items)</li>")
    refit = [totals[p] for p in ("P0", "P1", "P2") if p in totals]
    parts.append(f"<li><b>Refit P0+P1+P2: {money(sum(x[0] for x in refit))} – "
                 f"{money(sum(x[1] for x in refit))}</b></li></ul></div>")
    parts.append("<table><tr><th>Item</th><th>Priority</th><th>Status</th><th>Category</th>"
                 "<th>Low</th><th>High</th><th>Actual</th></tr>")
    for r in rows:
        parts.append("<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>".format(
            esc(str(r.get("Name", ""))), esc(str(r.get("Priority", ""))),
            esc(str(r.get("Status", ""))), esc(str(r.get("Category", ""))),
            money(r.get("Estimate Low ($)")), money(r.get("Estimate High ($)")),
            money(r.get("Actual Cost ($)"))))
    parts.append("</table>")
    return "".join(parts)

def load_page(snapshot, pid):
    """Accept MCP fetch JSON or pull_notion.py normalized JSON."""
    data = json.loads((snapshot / f"{pid}.json").read_text())
    if "content" in data and isinstance(data["content"], list):
        inner = json.loads(data["content"][0]["text"])
        return inner["title"], inner.get("page_last_edited_at", ""), inner["text"]
    return data["title"], data.get("last_edited", ""), data["content"]

def load_cost_rows(snapshot):
    data = json.loads((snapshot / "costs-rows.json").read_text())
    if "rows" in data:
        return data["rows"]
    return json.loads(data["content"][0]["text"])["results"]

def page_html(title, nav, banner, body, search_box=""):
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)} — Tally Ho (local mirror)</title>
<style>{CSS}</style></head>
<body>
<h1>{esc(title)}</h1>
<div class="banner">{banner}</div>
{nav}
{search_box}
{body}
<footer>Read-only local mirror of the Tally Ho Notion workspace. Edits happen in
Notion; re-run <code>pull_notion.py</code> + <code>render.py</code> to refresh.
Generated files are plain HTML — no server code runs when you read them.</footer>
</body></html>"""

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", default="snapshot")
    ap.add_argument("--out", default="site")
    args = ap.parse_args()
    snap, out = Path(args.snapshot), Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    banner = (f"<b>Read-only snapshot.</b> Generated {generated}. "
              "Notion edits made after this time are <b>not</b> in this mirror — "
              "re-run the pull to refresh. If this page disagrees with Notion, Notion wins.")
    entries, search = [], []
    for pid, slug in PAGES:
        title, last_edited, content = load_page(snap, pid)
        # De-duplicate leading emoji in MCP titles ("⛵ ⛵ Title", "💰 💸 Title"):
        # if the first two tokens are both emoji/symbols, drop the first.
        toks = title.split(" ", 2)
        if len(toks) >= 2 and not any(c.isalnum() for c in toks[0]) \
                and not any(c.isalnum() for c in toks[1]):
            title = " ".join(toks[1:])
        body = convert(content)
        if slug == "costs":
            try:
                body += "<h2>Project Costs — live rows</h2>" + costs_table(load_cost_rows(snap))
            except FileNotFoundError:
                body += "<p><i>Costs table not in this snapshot.</i></p>"
        entries.append((slug, title, last_edited))
        search.append({"title": title, "url": f"{slug}.html",
                       "text": strip_tags(content)[:6000]})
        (out / f"{slug}.html").write_text(
            page_html(title, "", banner, body,
                      f'<p style="color:#66707a">Last edited in Notion: {esc(last_edited)}</p>'),
            encoding="utf-8")
    nav = "<nav>" + "".join(
        f'<a href="{slug}.html">{esc(title)}</a>' for slug, title, _ in entries) + "</nav>"
    # Rewrite pages to include nav (second pass, cheap and keeps code simple).
    for slug, title, _ in entries:
        p = out / f"{slug}.html"
        html_doc = p.read_text(encoding="utf-8")
        html_doc = html_doc.replace('<div class="banner">', nav + '\n<div class="banner">', 1)
        p.write_text(html_doc, encoding="utf-8")
    # Hub index with client-side search over search.json.
    links = "".join(
        f'<li><a href="{slug}.html">{esc(title)}</a>'
        f' <span style="color:#66707a">(last edited {esc(le)})</span></li>'
        for slug, title, le in entries)
    index = page_html("Tally Ho — local mirror", "", banner, f"""
<p>Offline-readable copy of the core Tally Ho refit pages. Start here, or search below.</p>
<ul>{links}</ul>
<h2>Search this snapshot</h2>
<input class="searchbox" id="q" placeholder="Try: rigging, liferaft, watermaker, costs…">
<div id="results"></div>
<script>
fetch('search.json').then(r=>r.json()).then(pages=>{{
  const q=document.getElementById('q'), out=document.getElementById('results');
  q.addEventListener('input',()=>{{
    const needle=q.value.trim().toLowerCase();
    if(!needle){{out.innerHTML='';return;}}
    const hits=pages.filter(p=>(p.title+' '+p.text).toLowerCase().includes(needle)).slice(0,20);
    out.innerHTML=hits.length?hits.map(p=>{{
      const i=p.text.toLowerCase().indexOf(needle);
      const snip=i>=0?p.text.slice(Math.max(0,i-60),i+140):p.text.slice(0,200);
      return '<div class="result"><a href="'+p.url+'">'+p.title+'</a><br><span>'+snip+'</span></div>';
    }}).join(''):'<p>No matches in this snapshot.</p>';
  }});
}});
</script>
<p style="color:#66707a">Search covers page text in this snapshot only. It does not
search inside attached PDF manuals — those are listed on their pages when present.</p>
""")
    (out / "index.html").write_text(index, encoding="utf-8")
    (out / "search.json").write_text(json.dumps(search, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"Wrote {len(entries)} pages + search index to {out}/ (generated {generated})")

if __name__ == "__main__":
    main()
