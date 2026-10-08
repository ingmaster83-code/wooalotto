#!/usr/bin/env python3
"""우아복권 개인정보처리방침 페이지를 우아간식 것을 바탕으로 생성한다 (1회성)."""
import re
from pathlib import Path

root = Path(__file__).parent.parent
src = (root.parent / "wooasnack" / "privacy" / "index.html").read_text(encoding="utf-8")
src = src.replace("우아간식", "우아복권").replace("wooasnack.wooahouse.com", "wooalotto.wooahouse.com").replace("#EA580C", "#D97706")
src = re.sub(
    r"본 서비스의 간식 가게 정보는.*?서버로 전송되지 않습니다\.",
    "본 서비스의 복권 판매점 정보는 <strong>기획예산처가 공공데이터포털에 공개한 복권판매점 목록과 온라인복권 1등 당첨 판매점 현황</strong>을 기반으로 합니다. "
    "판매점 상호와 주소 등 공공데이터로 공개된 정보만 표시하며, 폐업·이전 반영에 시차가 있을 수 있습니다. "
    "'내 주변 복권방 찾기' 기능의 위치 정보는 브라우저 안에서만 계산되며 서버로 전송되지 않습니다.",
    src, flags=re.S)
(root / "privacy").mkdir(exist_ok=True)
(root / "privacy" / "index.html").write_text(src, encoding="utf-8")
print("privacy ok", "간식" in src)
