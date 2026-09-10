#!/usr/bin/env python3
"""Checks what the Gemini key in .env can actually reach, and exercises the
recognition prompt against the real schema.

    python3 tool/probe_gemini.py [image.jpg]

Reads GEMINI_API_KEY from .env. Never prints the key.
"""
import base64
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = "https://generativelanguage.googleapis.com/v1beta/models"

SYSTEM = """You are a food identification service for a nutrition app. You will receive one photograph of a meal.

Identify only the foods you can actually see. Be conservative: it is far better to omit an uncertain item than to invent one. Do not guess at ingredients hidden inside a dish; name the dish.

For each food, give a short everyday name a home cook would use ("rice", "grilled chicken", "green salad"), not a scientific or brand name.

Then judge whether the meal visibly contains each of three components:
- protein: meat, fish, eggs, dairy, beans, lentils, tofu, nuts
- fibre: vegetables, fruit, pulses, whole grains
- healthy_fat: oily fish, nuts, seeds, avocado, olive oil, tahini

Answer "present" only when you can see it, "possibly_missing" when you can see the meal clearly and it appears absent, and "uncertain" when the photograph does not let you tell.

Never estimate calories, weights, portions or nutritional values. Never describe any food as healthy, unhealthy, good or bad. Never comment on the person eating it.

If the image contains no food at all, return an empty foods array."""

SCHEMA = {
    "type": "object",
    "properties": {
        "foods": {
            "type": "array",
            "maxItems": 12,
            "items": {
                "type": "object",
                "properties": {"name": {"type": "string"}, "confidence": {"type": "number"}},
                "required": ["name", "confidence"],
            },
        },
        "components": {
            "type": "object",
            "properties": {
                "protein": {"type": "string", "enum": ["present", "possibly_missing", "uncertain"]},
                "fibre": {"type": "string", "enum": ["present", "possibly_missing", "uncertain"]},
                "healthy_fat": {"type": "string", "enum": ["present", "possibly_missing", "uncertain"]},
            },
            "required": ["protein", "fibre", "healthy_fat"],
        },
    },
    "required": ["foods", "components"],
}


def load_key() -> str:
    env = ROOT / ".env"
    if not env.exists():
        sys.exit("No .env — copy .env.example and add GEMINI_API_KEY.")
    for line in env.read_text().splitlines():
        if line.startswith("GEMINI_API_KEY="):
            return line.split("=", 1)[1].strip()
    sys.exit("GEMINI_API_KEY not set in .env")


def post(key: str, model: str, body: dict, attempts: int = 3):
    """Retries on 503. The API returns it under load often enough that the
    Worker will need the same handling — and a fallback to the manual builder
    when the retries run out."""
    for attempt in range(attempts):
        request = urllib.request.Request(
            f"{BASE}/{model}:generateContent",
            data=json.dumps(body).encode(),
            headers={"x-goog-api-key": key, "content-type": "application/json"},
        )
        try:
            return json.load(urllib.request.urlopen(request, timeout=180)), None
        except urllib.error.HTTPError as e:
            detail = e.read().decode()
            # "limit: 0" means the model needs billing, not that the key is wrong.
            if "limit: 0" in detail:
                return None, f"HTTP {e.code} — needs billing enabled"
            if e.code in (503, 429) and attempt < attempts - 1:
                time.sleep(2 * (attempt + 1))
                continue
            return None, f"HTTP {e.code} — {detail[:120]}"
    return None, "exhausted retries"


def main() -> None:
    key = load_key()

    print("reachable models")
    for model in ["gemini-3.7-flash", "gemini-3.6-flash", "gemini-3.1-flash-image"]:
        _, err = post(key, model, {"contents": [{"parts": [{"text": "say ok"}]}]})
        print(f"  {model:26} {'ok' if err is None else err}")

    parts = []
    if len(sys.argv) > 1:
        path = pathlib.Path(sys.argv[1])
        mime = "image/png" if path.suffix.lower() == ".png" else "image/jpeg"
        parts.append({
            "inlineData": {"mimeType": mime, "data": base64.b64encode(path.read_bytes()).decode()}
        })
        print(f"\nrecognising {path.name}")
    else:
        parts.append({"text": "The photograph shows a white plate with white rice and one "
                              "grilled chicken thigh on a wooden table."})
        print("\nno image given — running the described-meal case instead")

    data, err = post(key, "gemini-3.7-flash", {
        "systemInstruction": {"parts": [{"text": SYSTEM}]},
        "contents": [{"parts": parts}],
        "generationConfig": {
            "responseMimeType": "application/json",
            "responseSchema": SCHEMA,
            "temperature": 0,
        },
    })
    if err:
        sys.exit(err)
    print(json.dumps(json.loads(data["candidates"][0]["content"]["parts"][0]["text"]), indent=2))


if __name__ == "__main__":
    main()
