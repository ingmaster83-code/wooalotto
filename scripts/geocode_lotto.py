#!/usr/bin/env python3
"""복권판매점 목록(23.5k)의 도로명주소를 카카오 로컬 API로 지오코딩해 법정동/행정동/좌표를 얻는다.
이어하기 지원: geocode_lotto_cache.json 에 주소별 결과 누적."""
import csv, io, json, sys, time, re, threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import requests

sys.stdout.reconfigure(encoding="utf-8")
BASE = Path(__file__).parent
ENV = dict(l.strip().split("=", 1) for l in open(BASE.parent.parent / "hosppass" / ".env", encoding="utf-8") if "=" in l)
KEY = ENV["KAKAO_REST_KEY"]
CACHE = BASE.parent / "data" / "raw" / "geocode_lotto_cache.json"
URL = "https://dapi.kakao.com/v2/local/search/address.json"

raw = (BASE.parent / "data" / "raw" / "lotto_stores.csv").read_bytes()
try:
    text = raw.decode("utf-8-sig")
    if "판매점" not in text[:200]:
        raise UnicodeDecodeError("x", b"", 0, 1, "x")
except UnicodeDecodeError:
    text = raw.decode("cp949")
rows = list(csv.DictReader(io.StringIO(text)))
addrs = sorted({(r["도로명주소"] or "").strip() for r in rows if (r["도로명주소"] or "").strip()})
cache = json.loads(CACHE.read_text(encoding="utf-8")) if CACHE.exists() else {}
todo = [a for a in addrs if a not in cache]
print(f"주소 {len(addrs)}개, 캐시 {len(cache)}개, 남은 {len(todo)}개", flush=True)

lock = threading.Lock()
sess = requests.Session()
sess.headers["Authorization"] = "KakaoAK " + KEY


def query(q):
    for attempt in range(4):
        try:
            r = sess.get(URL, params={"query": q}, timeout=15)
            if r.status_code == 200:
                return r.json().get("documents", [])
            if r.status_code in (429, 500, 502, 503):
                time.sleep(1.5 * (attempt + 1))
                continue
            return None
        except requests.RequestException:
            time.sleep(1.5 * (attempt + 1))
    return None


def geocode(addr):
    variants = [addr]
    stripped = re.sub(r"\s*\(.*?\)", "", addr).strip()
    if stripped != addr:
        variants.append(stripped)
    stripped2 = re.sub(r",.*$", "", stripped).strip()
    stripped2 = re.sub(r"\s+(지하)?\d+층.*$", "", stripped2).strip()
    if stripped2 not in variants:
        variants.append(stripped2)
    for v in variants:
        docs = query(v)
        if docs:
            d = docs[0]
            a = d.get("address") or {}
            ra = d.get("road_address") or {}
            return {
                "dong": a.get("region_3depth_name") or ra.get("region_3depth_name") or "",
                "hdong": a.get("region_3depth_h_name") or "",
                "sido": a.get("region_1depth_name") or ra.get("region_1depth_name") or "",
                "sigungu": a.get("region_2depth_name") or ra.get("region_2depth_name") or "",
                "lot": a.get("address_name") or "",
                "lat": float(d["y"]), "lng": float(d["x"]),
            }
    return {}


done = 0
with ThreadPoolExecutor(max_workers=8) as ex:
    futs = {ex.submit(geocode, a): a for a in todo}
    for f in as_completed(futs):
        a = futs[f]
        try:
            res = f.result()
        except Exception as e:  # noqa
            res = {}
        with lock:
            cache[a] = res
            done += 1
            if done % 500 == 0:
                CACHE.write_text(json.dumps(cache, ensure_ascii=False), encoding="utf-8")
                print(f"  {done}/{len(todo)} (성공률 {sum(1 for v in cache.values() if v) / len(cache):.1%})", flush=True)

CACHE.write_text(json.dumps(cache, ensure_ascii=False), encoding="utf-8")
ok = sum(1 for v in cache.values() if v)
print(f"완료: {ok}/{len(cache)} 성공", flush=True)
