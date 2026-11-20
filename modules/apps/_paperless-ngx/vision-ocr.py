# Paperless post-consume hook: append a vision-model transcription to a
# document whose tesseract text looks poor (#986).
#
# Runs inside `paperless-ngx shell -c`, so Django is already set up and the
# ORM is importable. paperless calls the post-consume script with the
# consumer's environment plus DOCUMENT_ID and friends; the wrapper in
# modules/apps/paperless-ngx.nix adds VISION_OCR_* on top.
#
# Best effort by construction: the document is already stored when this
# runs, and a non-zero exit makes paperless report the consumption as
# failed. Every error is logged and swallowed.
#
# Only counts and decisions go to stdout. paperless logs it line by line
# into the consumer journal, and from there into VictoriaLogs, so document
# text never gets printed.

import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.request

MARKER = "--- vision OCR"
# One request per page, so this caps the GPU time one consumption can take.
MAX_PAGES = 5
# Wall-clock budget for all vision requests together. paperless runs this
# script inside the consume task with no timeout of its own, and celery
# hard-kills that task at PAPERLESS_WORKER_TIMEOUT (1800 s default), which
# would report a stored document as a failed consumption. tesseract has
# already spent some of that budget by the time this runs.
BUDGET_SECONDS = 900
# Per request. Generous because amos1 loads the model cold on the first page.
REQUEST_TIMEOUT = 300
# Long side in pixels. The two calibration photos were 1889x2869 and
# 1954x1431. llama.cpp's mtmd resizes to the model's own budget anyway, so
# going larger only adds upload size.
MAX_SIDE = 2048
# Fewer non-space characters than this per page in the original's own text
# layer means the text paperless holds came from tesseract.
NATIVE_TEXT_CHARS_PER_PAGE = 50
# Fraction of whitespace tokens that are dictionary words. Calibrated on
# amos1's 16 documents on 2026-11-20: the two handwritten photos scored
# 0.56 and 0.37, every other document 0.63 or higher, and the one clean
# OCR'd scan 0.85.
POOR_OCR_RATIO = 0.6
PROMPT = (
    "Transcribe every piece of text in this document photo, including all "
    "handwritten entries, exactly as written. Do not summarize or correct "
    "anything. Output plain text in reading order; for form fields write the "
    "printed label followed by the handwritten value. If a handwritten word "
    "is illegible, write [illegible]."
)


def log(msg: str) -> None:
    print(f"vision-ocr: {msg}", flush=True)


def word_ratio(text: str, words: set[str]) -> float:
    tokens = text.split()
    if not tokens:
        return 0.0
    known = 0
    for token in tokens:
        bare = re.sub(r"^\W+|\W+$", "", token).lower()
        if len(bare) >= 2 and bare in words:
            known += 1
    return known / len(tokens)


def has_native_text(source: Path, mime: str, pages: int) -> bool:
    if mime.startswith("image/"):
        return False
    if mime != "application/pdf":
        # Office documents, mail, plain text: never tesseract's output.
        return True
    out = subprocess.run(
        ["pdftotext", "-l", str(MAX_PAGES), str(source), "-"],
        capture_output=True,
        check=True,
    ).stdout.decode("utf-8", errors="ignore")
    chars = len(re.sub(r"\s", "", out))
    return chars >= NATIVE_TEXT_CHARS_PER_PAGE * min(pages, MAX_PAGES)


def page_images(doc, workdir: Path) -> list[tuple[str, bytes]]:
    if doc.has_archive_version:
        pdf = doc.archive_path
    elif doc.mime_type == "application/pdf":
        pdf = doc.source_path
    elif doc.mime_type in ("image/jpeg", "image/png"):
        return [(doc.mime_type, doc.source_path.read_bytes())]
    else:
        # TIFF, WebP, HEIC and the rest aren't safe bets for llama.cpp's
        # image loader. paperless archives images by default, so this
        # branch should only be reached with archiving turned off.
        return []
    subprocess.run(
        [
            "pdftoppm",
            "-jpeg",
            "-scale-to",
            str(MAX_SIDE),
            "-l",
            str(MAX_PAGES),
            str(pdf),
            str(workdir / "page"),
        ],
        check=True,
    )
    return [("image/jpeg", p.read_bytes()) for p in sorted(workdir.glob("page*.jpg"))]


def transcribe(mime: str, image: bytes, timeout: float) -> tuple[str, str]:
    body = {
        "model": os.environ["VISION_OCR_MODEL"],
        "temperature": 0,
        "max_tokens": 4096,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": f"data:{mime};base64,"
                            + base64.b64encode(image).decode()
                        },
                    },
                    {"type": "text", "text": PROMPT},
                ],
            }
        ],
    }
    request = urllib.request.Request(
        os.environ["VISION_OCR_ENDPOINT"].rstrip("/") + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {os.environ['PAPERLESS_AI_LLM_API_KEY']}",
        },
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        reply = json.load(response)
    choice = reply["choices"][0]
    if choice.get("finish_reason") == "length":
        log("a page hit max_tokens; its transcription is truncated")
    content = (choice.get("message") or {}).get("content") or ""
    return reply.get("model", body["model"]), content.strip()


def main() -> None:
    from documents.models import Document
    from documents.search import get_backend
    from documents.signals import document_updated

    doc = Document.objects.get(pk=int(os.environ["DOCUMENT_ID"]))
    content = doc.content or ""
    if MARKER in content:
        log(f"document {doc.pk}: already has a vision transcription")
        return

    pages = doc.page_count or 1
    if has_native_text(doc.source_path, doc.mime_type, pages):
        log(f"document {doc.pk}: has its own text layer, skipping")
        return

    words = {
        line.strip().lower()
        for line in Path(os.environ["VISION_OCR_WORDLIST"])
        .read_text(encoding="latin-1")
        .splitlines()
    }
    ratio = word_ratio(content, words)
    if ratio >= POOR_OCR_RATIO:
        log(f"document {doc.pk}: OCR word ratio {ratio:.2f}, keeping tesseract only")
        return
    log(f"document {doc.pk}: OCR word ratio {ratio:.2f}, transcribing")

    with tempfile.TemporaryDirectory() as tmp:
        images = page_images(doc, Path(tmp))
    if not images:
        log(f"document {doc.pk}: no page images to send ({doc.mime_type})")
        return

    # Page by page, keeping whatever succeeded: the marker stops any second
    # attempt, so a failed page is recorded rather than retried.
    deadline = time.monotonic() + BUDGET_SECONDS
    parts, model, done = [], None, 0
    for n, (mime, image) in enumerate(images, 1):
        remaining = deadline - time.monotonic()
        if remaining < 30:
            log(f"document {doc.pk}: budget spent before page {n}")
            parts.append(f"[page {n}: not transcribed, time budget spent]")
            continue
        try:
            model, text = transcribe(mime, image, min(REQUEST_TIMEOUT, remaining))
        except Exception as exc:  # noqa: BLE001 - one page must not lose the rest
            log(f"document {doc.pk}: page {n} failed: {exc!r}")
            parts.append(f"[page {n}: not transcribed]")
            continue
        done += bool(text)
        parts.append(f"[page {n}]\n{text}" if len(images) > 1 else text)

    if not done:
        log(f"document {doc.pk}: vision returned nothing")
        return

    # Say so when pages past MAX_PAGES were never sent, so a partial
    # transcription can't be mistaken for a whole one.
    scope = f", pages 1-{len(images)} of {pages}" if pages > len(images) else ""
    # Appended, never replacing: tesseract never invents text, and it keeps
    # whatever the printed parts of the page gave it for search.
    doc.content = (
        f"{content.rstrip()}\n\n{MARKER} ({model}{scope}) ---\n" + "\n\n".join(parts)
    )
    doc.save(update_fields=["content", "modified"])

    # What the REST API's document update does after a content edit
    # (DocumentViewSet.update in 3.4.2): fire document_updated, which
    # re-queues the LLM index embedding and runs "updated" workflows, then
    # reindex full-text search. A version's text belongs to its root.
    root = doc.root_document if doc.root_document_id else doc
    document_updated.send(sender=Document, document=root)
    get_backend().add_or_update(Document.objects.get(pk=root.pk))
    log(
        f"document {doc.pk}: appended {done}/{len(images)} page(s) of {pages} from {model}"
    )


try:
    main()
except Exception as exc:  # noqa: BLE001 - must never fail the consumption
    log(f"failed, leaving the document as tesseract left it: {exc!r}")
