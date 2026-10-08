#!/usr/bin/env python3
"""geocode_lotto.py 에서 실패한 주소를 개편된 행정구역명(전남광주/화성시 신설구 등)을 보정해 재시도."""
import json, re, sys, time, threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import requests

sys.stdout.reconfigure(encoding="utf-8")
BASE = Path(__file__).parent
ENV = dict(l.strip().split("=", 1) for l in open(BASE.parent.parent / "hosppass" / ".env", encoding="utf-8") if "=" in l)
KEY = ENV["KAKAO_REST_KEY"]
CACHE = BASE.parent / "data" / "raw" / "geocode_lotto_cache.json"
cache = json.loads(CACHE.read_text(encoding="utf-8"))
bad = [a for a, v in cache.items() if not v]
print("재시도 대상", len(bad), flush=True)

sess = requests.Session()
sess.headers["Authorization"] = "KakaoAK " + KEY
NEW_DISTRICTS_HWASEONG = ("효행구", "만세구", "병점구", "동탄구")


def query(q, kind="address"):
    url = "https://dapi.kakao.com/v2/local/search/" + ("address.json" if kind == "address" else "keyword.json")
    for attempt in range(4):
        try:
            r = sess.get(url, params={"query": q}, timeout=15)
            if r.status_code == 200:
                return r.json().get("documents", [])
            if r.status_code in (429, 500, 502, 503):
                time.sleep(1.5 * (attempt + 1))
                continue
            return None
        except requests.RequestException:
            time.sleep(1.5 * (attempt + 1))
    return None


def variants(addr):
    toks = addr.split()
    out = []
    if toks and toks[0] == "전남광주" and len(toks) > 1:
        sido = "광주" if toks[1].endswith("구") else "전남"
        out.append(" ".join([sido] + toks[1:]))
        base = out[-1]
    else:
        base = addr
    t = base.split()
    if len(t) > 2 and t[1] == "화성시" and t[2] in NEW_DISTRICTS_HWASEONG:
        out.append(" ".join([t[0], t[1]] + t[3:]))
    if len(t) > 2 and t[0] == "인천" and t[1] in ("서해구", "제물포구", "영종구", "검단구"):
        out.append(" ".join([t[0]] + t[2:]))
    cleaned = []
    for v in out + [base]:
        v2 = re.sub(r"\s*\(.*?\)", "", v).strip()
        v2 = re.sub(r"\s+(지하)?\d+층.*$", "", v2).strip()
        v2 = re.sub(r"\s+\d+(,\d+)*호.*$", "", v2).strip()
        for x in (v, v2):
            if x not in cleaned:
                cleaned.append(x)
    return cleaned


def parse(d):
    a = d.get("address") or {}
    ra = d.get("road_address") or {}
    return {"dong": a.get("region_3depth_name") or ra.get("region_3depth_name") or "", "hdong": a.get("region_3depth_h_name") or "",
            "sido": a.get("region_1depth_name") or ra.get("region_1depth_name") or "",
            "sigungu": a.get("region_2depth_name") or ra.get("region_2depth_name") or "",
            "lot": a.get("address_name") or "", "lat": float(d["y"]), "lng": float(d["x"])}


def retry(addr):
    for v in variants(addr):
        docs = query(v)
        if docs:
            return parse(docs[0])
    return {}


fixed = 0
lock = threading.Lock()
with ThreadPoolExecutor(max_workers=8) as ex:
    futs = {ex.submit(retry, a): a for a in bad}
    for f in as_completed(futs):
        a = futs[f]
        try:
            res = f.result()
        except Exception:
            res = {}
        if res:
            with lock:
                cache[a] = res
                fixed += 1
print(f"보정 성공 {fixed}/{len(bad)}", flush=True)
CACHE.write_text(json.dumps(cache, ensure_ascii=False), encoding="utf-8")
print("전체 성공률", sum(1 for v in cache.values() if v) / len(cache))
