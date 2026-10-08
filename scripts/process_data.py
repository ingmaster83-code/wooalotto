#!/usr/bin/env python3
"""
process_data.py - 기획예산처 복권판매점 목록(23.5k행) + 온라인복권 1등 당첨 판매점 현황(463곳)을 합쳐
페이지 생성용 JSON으로 가공한다.

입력(data/raw): lotto_stores.csv(판매점명,도로명주소,판매점종류 1=온라인/2=인쇄), lotto_win.csv(상호,지역,1등 자동 당첨 건수),
               geocode_lotto_cache.json(주소→카카오 지오코딩: 법정동/행정동/좌표)
출력: _rawdata/lot_{시도}.json, _rawdata/dongs.json, search_index.json, assets/dongs.json
"""
import csv, io, json, re, sys, hashlib, math
from pathlib import Path
from collections import Counter, defaultdict
import numpy as np

sys.stdout.reconfigure(encoding="utf-8")
ROOT = Path(__file__).parent.parent
RAW = ROOT / "data" / "raw"
OUT = ROOT / "_rawdata"

SIDO_MAP = {"서울": "서울", "부산": "부산", "대구": "대구", "인천": "인천", "광주": "광주", "대전": "대전", "울산": "울산", "세종": "세종",
            "경기": "경기", "강원": "강원", "충북": "충북", "충남": "충남", "전북": "전북", "전남": "전남", "경북": "경북", "경남": "경남", "제주": "제주"}


def read_csv(path):
    raw = path.read_bytes()
    try:
        text = raw.decode("utf-8-sig")
        if "�" in text:
            raise UnicodeDecodeError("x", b"", 0, 1, "x")
    except UnicodeDecodeError:
        text = raw.decode("cp949")
    return list(csv.DictReader(io.StringIO(text)))


def clean(s):
    return re.sub(r"\s+", " ", str(s or "").strip())


def norm_name(s):
    return re.sub(r"[\s\-_\.\(\)\[\]·]", "", clean(s)).lower()


def split_region(addr):
    """주소 문자열에서 (시도, 시군구) 추출. 전남광주 → 구면 광주, 시/군이면 전남. 세종은 '세종시'."""
    toks = clean(addr).split()
    if not toks:
        return None, None
    first = toks[0]
    if first == "세종":
        return "세종", "세종시"
    if len(toks) < 2:
        return None, None
    sg = toks[1]
    rest = toks[2:]
    if first == "전남광주":
        do = "광주" if sg.endswith("구") else "전남"
    else:
        do = SIDO_MAP.get(first)
    if not do:
        return None, None
    if sg.endswith("시") and rest and rest[0].endswith("구") and len(rest[0]) > 1:
        sg = f"{sg} {rest[0]}"
    return do, sg


def fmt_dong(d):
    return d if d else "기타"


def make_slug(name, addr):
    base = re.sub(r"[^\w가-힣\s-]", "", name).strip()
    base = re.sub(r"\s+", "-", base)
    base = re.sub(r"-+", "-", base)[:24].strip("-")
    h = hashlib.md5(f"{name}|{addr}".encode("utf-8")).hexdigest()[:6]
    return f"{base}-{h}" if base else h


def haversine_matrix(lat1, lng1, lat2, lng2):
    p = math.pi / 180
    a = np.sin((lat2[None, :] - lat1[:, None]) * p / 2) ** 2 + \
        np.cos(lat1[:, None] * p) * np.cos(lat2[None, :] * p) * np.sin((lng2[None, :] - lng1[:, None]) * p / 2) ** 2
    return 12742 * np.arcsin(np.sqrt(a))


def main():
    rows = read_csv(RAW / "lotto_stores.csv")
    geo = json.loads((RAW / "geocode_lotto_cache.json").read_text(encoding="utf-8"))
    wins_raw = read_csv(RAW / "lotto_win.csv")

    # ---- 판매점 병합 (같은 상호+주소는 온라인/인쇄 종류 합치기)
    merged = {}
    skipped = Counter()
    for r in rows:
        name, addr = clean(r.get("판매점명")), clean(r.get("도로명주소"))
        if not name or not addr:
            skipped["empty"] += 1
            continue
        key = (name, addr)
        kind = clean(r.get("판매점종류"))
        if key not in merged:
            merged[key] = {"name": name, "addr": addr, "kinds": set()}
        merged[key]["kinds"].add(kind)

    # 같은 상호가 온라인/인쇄 복권으로 따로 등록되면서 층·호수만 다른 경우가 많아 건물 번지까지의 주소로 한 곳으로 합친다.
    def addr_base(addr):
        toks = clean(addr).split()
        for k, t in enumerate(toks):
            if k >= 2 and re.match(r"^\d+(-\d+)?,?$", t):
                return " ".join(toks[:k + 1]).rstrip(",")
        return clean(addr)

    groups = defaultdict(list)
    for (name, addr), m in merged.items():
        groups[(norm_name(name), addr_base(addr))].append(m)
    items, seen = [], Counter()
    for (_nn, _base), ms in groups.items():
        kinds = set().union(*[m["kinds"] for m in ms])
        rep = next((m for m in ms if "1" in m["kinds"]), ms[0])
        name, addr = rep["name"], rep["addr"]
        do, sg = split_region(addr)
        if not do or not sg:
            skipped["no_region"] += 1
            continue
        g = geo.get(addr) or next((geo.get(m["addr"]) for m in ms if geo.get(m["addr"])), None) or {}
        dong = fmt_dong(clean(g.get("dong")))
        slug = make_slug(name, addr)
        seen[slug] += 1
        if seen[slug] > 1:
            slug = f"{slug}-{seen[slug]}"
        items.append({
            "slug": slug, "storeName": name, "addr": addr, "doShort": do, "sigungu": sg, "sgSlug": sg.replace(" ", "-"), "dong": dong,
            "hdong": clean(g.get("hdong")), "lot": clean(g.get("lot")),
            "online": "1" in kinds, "printed": "2" in kinds,
            "lat": g.get("lat"), "lng": g.get("lng"), "winCount": 0, "winMatched": False, "winPossible": 0, "winSame": 0,
        })
    print(f"판매점 {len(items):,}곳 (제외 {dict(skipped)}), 지오코딩 동 확보 {sum(1 for i in items if i['dong'] != '기타'):,}")

    # ---- 당첨 판매점 매칭 (상호 정규화 + 시도/시군구)
    idx = defaultdict(list)
    for it in items:
        idx[(norm_name(it["storeName"]), it["doShort"], it["sigungu"])].append(it)
    win_rows, matched, ambiguous, unmatched, skipped_web = [], 0, 0, 0, 0
    for w in wins_raw:
        name, region, cnt = clean(w.get("상호")), clean(w.get("지역")), int(clean(w.get("1등 자동 당첨 건수")) or 0)
        if "인터넷" in name and "복권" in name:
            skipped_web += 1
            continue
        toks = region.split()
        if not toks:
            continue
        do = SIDO_MAP.get(toks[0])
        sg = " ".join(toks[1:]) if len(toks) > 1 else ("세종시" if toks[0] == "세종" else "")
        if toks[0] == "세종":
            sg = "세종시"
        cands = idx.get((norm_name(name), do, sg), [])
        # 시군구 표기 차이(예: '수원시 팔달구' vs '수원시') 보정
        if not cands:
            for (nn, d, s), lst in idx.items():
                if nn == norm_name(name) and d == do and (s.startswith(sg) or sg.startswith(s)):
                    cands = lst
                    break
        rec = {"name": name, "region": region, "count": cnt, "do": do, "sigungu": sg, "slugs": [c["slug"] for c in cands]}
        if len(cands) == 1:
            c = cands[0]
            c["winCount"] += cnt
            c["winMatched"] = True
            matched += 1
        elif len(cands) > 1:
            ambiguous += 1
            for c in cands:
                c["winPossible"] = c.get("winPossible", 0) + cnt
                c["winSame"] = len(cands)
        else:
            unmatched += 1
        win_rows.append(rec)
    print(f"당첨점 {len(win_rows)}곳: 단일매칭 {matched}, 동명다수 {ambiguous}, 미매칭 {unmatched}, 인터넷사이트 제외 {skipped_web}")

    # ---- 동 단위 집계 & 순위
    by_dong = defaultdict(list)
    for i in items:
        by_dong[(i["doShort"], i["sigungu"], i["dong"])].append(i)
    for lst in by_dong.values():
        lst.sort(key=lambda x: (-x["winCount"], x["storeName"], x["slug"]))
        for rank, i in enumerate(lst, 1):
            i["dongCount"] = len(lst)
            i["dongRank"] = rank

    # ---- 근처 판매점
    geo_items = [i for i in items if i["lat"] is not None]
    glat = np.array([i["lat"] for i in geo_items])
    glng = np.array([i["lng"] for i in geo_items])
    for i in items:
        i["near"] = []
    CH = 600
    for s in range(0, len(geo_items), CH):
        d = haversine_matrix(glat[s:s + CH], glng[s:s + CH], glat, glng)
        for r in range(d.shape[0]):
            d[r, s + r] = 1e9
        idx_k = np.argpartition(d, 8, axis=1)[:, :8]
        for r in range(idx_k.shape[0]):
            row = idx_k[r][np.argsort(d[r, idx_k[r]])]
            me = geo_items[s + r]
            me["near"] = [{"slug": geo_items[j]["slug"], "name": geo_items[j]["storeName"], "dong": geo_items[j]["dong"], "m": int(d[r, j] * 1000),
                           "win": geo_items[j]["winCount"]} for j in row if d[r, j] < 2.0][:6]
    print("근처 판매점 계산 완료", flush=True)

    # ---- 동 허브
    dong_keys = sorted(k for k in by_dong.keys() if k[2] != "기타")
    cen = {}
    for k in dong_keys:
        pts = [(i["lat"], i["lng"]) for i in by_dong[k] if i["lat"] is not None]
        if pts:
            cen[k] = (sum(a for a, _ in pts) / len(pts), sum(b for _, b in pts) / len(pts))
    dk = [k for k in dong_keys if k in cen]
    dlat = np.array([cen[k][0] for k in dk])
    dlng = np.array([cen[k][1] for k in dk])
    dd = haversine_matrix(dlat, dlng, dlat, dlng)
    for r in range(len(dk)):
        dd[r, r] = 1e9
    dd_idx = np.argsort(dd, axis=1)[:, :8]
    sg_slug_of = {}
    for i in items:
        sg_slug_of[(i["doShort"], i["sigungu"])] = i["sgSlug"]
    dong_out = []
    for r, k in enumerate(dk):
        near = []
        for j in dd_idx[r]:
            if dd[r, j] > 5.0:
                break
            nk = dk[j]
            near.append({"do": nk[0], "sg": nk[1], "sgSlug": sg_slug_of[(nk[0], nk[1])], "dong": nk[2], "n": len(by_dong[nk])})
        dong_out.append({"do": k[0], "sigungu": k[1], "sgSlug": sg_slug_of[(k[0], k[1])], "dong": k[2], "lat": round(cen[k][0], 5), "lng": round(cen[k][1], 5),
                         "nearDongs": near, "shopCount": len(by_dong[k]), "winTotal": sum(i["winCount"] for i in by_dong[k])})
    have = {(d["do"], d["sigungu"], d["dong"]) for d in dong_out}
    for k in dong_keys:
        if k not in have:
            dong_out.append({"do": k[0], "sigungu": k[1], "sgSlug": sg_slug_of[(k[0], k[1])], "dong": k[2], "lat": None, "lng": None,
                             "nearDongs": [], "shopCount": len(by_dong[k]), "winTotal": sum(i["winCount"] for i in by_dong[k])})
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "dongs.json").write_text(json.dumps(dong_out, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    light = [{"d": d["do"], "s": d["sigungu"], "g": d["sgSlug"], "n": d["dong"], "a": d["lat"], "o": d["lng"]} for d in dong_out if d["lat"] is not None]
    (ROOT / "assets").mkdir(exist_ok=True)
    (ROOT / "assets" / "dongs.json").write_text(json.dumps(light, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    (OUT / "wins.json").write_text(json.dumps(win_rows, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")

    # ---- 시도별 샤드
    for old in OUT.glob("lot_*.json"):
        old.unlink()
    by_do = defaultdict(list)
    for i in items:
        by_do[i["doShort"]].append(i)
    for do, g in by_do.items():
        (OUT / f"lot_{do}.json").write_text(json.dumps(g, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    index = [{"n": i["storeName"], "s": i["slug"], "do": i["doShort"], "sg": i["sigungu"], "dg": i["dong"], "w": i["winCount"]} for i in items]
    (ROOT / "search_index.json").write_text(json.dumps(index, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"판매점 {len(items):,}곳, 동 허브 {len(dong_out):,}개, 시도 {len(by_do)}개, 당첨 매칭 점포 {sum(1 for i in items if i['winMatched'])}곳")


if __name__ == "__main__":
    main()
