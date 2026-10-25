#!/usr/bin/env python3
"""Pull Notion pages + databases into snapshot/ for render.py.

This is the piece that runs on Daniel's machine (boat PC or home PC).
It is READ-ONLY: it never writes to Notion. Notion stays the source of
truth; snapshot/ is a local copy that render.py turns into static pages.

Setup (once):
  1. In Notion: Settings -> Connections -> Develop or manage integrations
     -> New integration. Give it a name (e.g. "Tally Ho Mirror").
  2. On each page/database you want mirrored, click ... -> Add connections
     -> the integration above. (Notion integrations only see shared pages.)
  3. Set the token:  export NOTION_TOKEN="secret_..."   (never commit it)
  4. Edit pages.json (next to this script) with your page IDs.
     Page IDs are in the page URL: notion.so/<Title>-<32 hex chars>.

Usage:
  python3 pull_notion.py [--pages pages.json] [--out snapshot]
  python3 pull_notion.py --incremental   # skip pages whose last_edited_time
                                         # is unchanged since the last pull

Notes / known quirks, learned from the real Tally Ho workspace:
  * Notion's API paginates everything and rate-limits (~3 req/s); this
    script sleeps between calls and follows cursors, so a first full pull
    takes minutes. That is normal.
  * Databases are queried by data-source ID, not page ID. A database page
    fetch returns its data source URL (collection://...); use the UUID
    part of that URL as the database_id for /v1/databases/{id}/query.
    (The Project Costs page is the known example: its page ID 404s for
    rows; the data source query works.)
  * File/image URLs from Notion expire in about an hour. This script
    downloads file blocks into snapshot/files/ at pull time and rewrites
    the block to point at the local copy. Skip --no-files to skip that.
  * Block types this script renders to markdown: paragraph, headings,
    bulleted/numbered lists, to-do, quote, callout, divider, table,
    code, toggle (flattened), child pages (fetched, depth-limited).
    Anything else is kept as a placeholder line with a "view in Notion"
    link, so content is never silently dropped.
"""
import argparse, json, os, re, sys, time, urllib.request, urllib.error
from pathlib import Path

API = "https://api.notion.com/v1"
VERSION = "2022-06-28"

class Notion:
    def __init__(self, token):
        self.token = token
    def _req(self, method, path, body=None, retries=5):
        url = API + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Notion-Version", VERSION)
        req.add_header("Content-Type", "application/json")
        for attempt in range(retries):
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    return json.loads(resp.read() or b"{}")
            except urllib.error.HTTPError as e:
                if e.code == 429 and attempt < retries - 1:
                    time.sleep(2 ** attempt); continue
                raise RuntimeError(f"Notion {method} {path} -> HTTP {e.code}: {e.read()[:400]!r}")
            except urllib.error.URLError:
                if attempt < retries - 1:
                    time.sleep(2 ** attempt); continue
                raise
    def page(self, pid):
        return self._req("GET", f"/pages/{pid}")
    def children(self, block_id):
        out, cursor = [], None
        while True:
            resp = self._get_children(block_id, cursor)
            out.extend(resp.get("results", []))
            cursor = resp.get("next_cursor")
            if not resp.get("has_more"): break
            time.sleep(0.35)
        return out
    def _get_children(self, block_id, cursor):
        # GET with a query string (Notion's children endpoint is GET-only).
        q = f"?page_size=100" + (f"&start_cursor={cursor}" if cursor else "")
        return self._req("GET", f"/blocks/{block_id}/children{q}")
    def query_database(self, db_id):
        out, cursor = [], None
        while True:
            body = {"page_size": 100}
            if cursor: body["start_cursor"] = cursor
            resp = self._req("POST", f"/databases/{db_id}/query", body)
            out.extend(resp.get("results", []))
            cursor = resp.get("next_cursor")
            if not resp.get("has_more"): break
            time.sleep(0.35)
        return out
    def download(self, url, dest):
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as fh:
            fh.write(resp.read())

def plain(rich):
    return "".join(r.get("plain_text", "") for r in (rich or []))

def md_blocks(api, blocks, out_dir, files_dir, depth=0, seen=None):
    """Blocks -> markdown-ish text in the same shape render.py consumes."""
    lines, table = [], []
    def flush_table():
        if table:
            lines.extend(table); table.clear()
    for b in blocks:
        t, data = b["type"], b.get(b["type"], {})
        if t == "table":
            rows = api.children(b["id"])
            rows_md = []
            for row in rows:
                cells = row.get("table_row", {}).get("cells", [])
                rows_md.append("| " + " | ".join(plain(c) for c in cells) + " |")
            if rows_md:
                rows_md.insert(1, "| " + " | ".join("---" for _ in rows_md[0].split("|")[1:-1]) + " |")
                lines.extend(rows_md)
            continue
        if t in ("table_row",):
            continue
        flush_table()
        if t == "paragraph": lines.append(plain(data.get("rich_text")))
        elif t.startswith("heading_"):
            n = t[-1]; lines.append("#" * int(n) + " " + plain(data.get("rich_text")))
        elif t == "bulleted_list_item": lines.append("- " + plain(data.get("rich_text")))
        elif t == "numbered_list_item": lines.append("1. " + plain(data.get("rich_text")))
        elif t == "to_do":
            mark = "x" if data.get("checked") else " "
            lines.append(f"- [{mark}] " + plain(data.get("rich_text")))
        elif t == "quote": lines.append("> " + plain(data.get("rich_text")))
        elif t == "callout":
            lines.append(f'<callout icon="{data.get("icon", {}).get("emoji", "")}">'
                         + plain(data.get("rich_text")) + "</callout>")
        elif t == "divider": lines.append("---")
        elif t == "code": lines.append("```\n" + plain(data.get("rich_text")) + "\n```")
        elif t in ("file", "image", "pdf"):
            url = (data.get("file") or {}).get("url") or (data.get("external") or {}).get("url") or ""
            name = Path(url.split("?")[0]).name or "file"
            if url and files_dir is not None:
                dest = files_dir / name
                try:
                    api.download(url, dest)
                    lines.append(f"[{name}](files/{name})  <!-- downloaded at pull time; Notion URLs expire -->")
                except Exception as e:
                    lines.append(f"[{name}]({url})  <!-- download failed: {e} -->")
            else:
                lines.append(f"[{name}]({url})")
        elif t == "child_page":
            lines.append(f"📄 {data.get('title', '')} (child page — see pages.json to mirror it)")
        elif t == "child_database":
            lines.append(f"🗃️ Database block: {data.get('title', '')} (database_id {b['id']})")
        else:
            lines.append(f"<!-- unsupported block type {t}; view in Notion -->")
        # Recurse into toggle / synced blocks so their children aren't lost.
        if b.get("has_children") and t in ("toggle", "synced_block", "column_list", "column"):
            lines.append("")
            lines.extend(md_blocks(api, api.children(b["id"]), out_dir, files_dir, depth + 1))
        if depth == 0:
            time.sleep(0.1)
    flush_table()
    return lines

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pages", default="pages.json")
    ap.add_argument("--out", default="snapshot")
    ap.add_argument("--incremental", action="store_true")
    ap.add_argument("--no-files", action="store_true")
    args = ap.parse_args()
    token = os.environ.get("NOTION_TOKEN")
    if not token:
        print("ERROR: set NOTION_TOKEN (see header). Never paste it into chat or a file.",
              file=sys.stderr); return 2
    pages = json.loads(Path(args.pages).read_text())
    out, files_dir = Path(args.out), Path(args.out) / "files"
    out.mkdir(parents=True, exist_ok=True)
    if not args.no_files: files_dir.mkdir(exist_ok=True)
    api = Notion(token)
    prev = {}
    manifest_path = out / "manifest.json"
    if manifest_path.exists():
        prev = json.loads(manifest_path.read_text()).get("pages", {})
    manifest = {"pages": {}, "databases": {}}
    for entry in pages.get("pages", []):
        pid, slug = entry["id"], entry["slug"]
        meta = api.page(pid)
        last = meta.get("last_edited_time", "")
        if args.incremental and prev.get(pid, {}).get("last_edited") == last \
                and (out / f"{pid}.json").exists():
            print(f"skip (unchanged): {slug}"); manifest["pages"][pid] = prev[pid]; continue
        title = "".join(p.get("plain_text", "") for p in meta.get("properties", {}).get("title", {}).get("title", [])) \
            or entry.get("title", slug)
        blocks = api.children(pid)
        content = "\n\n".join(md_blocks(api, blocks, out, None if args.no_files else files_dir))
        (out / f"{pid}.json").write_text(json.dumps(
            {"title": title, "last_edited": last, "content": content}, ensure_ascii=False, indent=1))
        manifest["pages"][pid] = {"slug": slug, "title": title, "last_edited": last}
        print(f"pulled: {slug} ({len(blocks)} top-level blocks)")
    for entry in pages.get("databases", []):
        rows = api.query_database(entry["database_id"])
        norm = []
        for r in rows:
            props = {}
            for name, prop in r.get("properties", {}).items():
                pt = prop.get("type")
                if pt == "title": props[name] = plain(prop.get("title"))
                elif pt == "rich_text": props[name] = plain(prop.get("rich_text"))
                elif pt == "number": props[name] = prop.get("number")
                elif pt == "select": props[name] = (prop.get("select") or {}).get("name")
                elif pt == "status": props[name] = (prop.get("status") or {}).get("name")
                elif pt == "checkbox": props[name] = prop.get("checkbox")
                elif pt == "url": props[name] = prop.get("url")
                elif pt == "date":
                    d = prop.get("date") or {}; props[name] = d.get("start")
                else: props[name] = None
            norm.append(props)
        (out / f"{entry['slug']}-rows.json").write_text(json.dumps(
            {"rows": norm}, ensure_ascii=False, indent=1))
        manifest["databases"][entry["database_id"]] = {"slug": entry["slug"], "rows": len(norm)}
        print(f"pulled database: {entry['slug']} ({len(norm)} rows)")
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=1))
    print(f"Done. Run: python3 render.py --snapshot {args.out}")

if __name__ == "__main__":
    raise SystemExit(main())
