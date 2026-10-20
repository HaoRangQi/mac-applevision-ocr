"""Post-correction rules for Vision's stable Chinese misreads.

Vision's zh-Hans model has a handful of reproducible confusions on printed
text (it reads 的 as 钓/哟/菂, 入 as 人, and so on). The rules below only
cover pairs that cannot occur as valid modern Chinese, so they are safe to
apply unconditionally.
"""

from __future__ import annotations

import re

# Characters Vision substitutes for 的.
DE_CONFUSIONS = set("钓哟菂旳酌时")

# (wrong, right) pairs. Every left-hand side is a non-word in modern Chinese.
RULES: list[tuple[str, str]] = [
    ("竟争", "竞争"), ("竟选", "竞选"), ("竟标", "竞标"), ("竟赛", "竞赛"), ("竟技", "竞技"),
    ("优心", "忧心"),
    ("债劵", "债券"),
    ("吹洲", "欧洲"), ("欢洲", "欧洲"), ("阶洲", "欧洲"),
    ("吹盟", "欧盟"), ("欢盟", "欧盟"), ("阶盟", "欧盟"),
    ("吹美", "欧美"), ("阶美", "欧美"),
    ("吹元", "欧元"), ("欢元", "欧元"), ("阶元", "欧元"),
    ("风凰", "凤凰"),
    ("严业", "产业"),
    ("开婚", "开始"),
    ("纱漠", "沙漠"),
    ("臂感", "骨感"), ("貴感", "骨感"), ("肯感", "骨感"),
    ("叉薄", "又薄"),
    ("—一", "——"),
    ("买人", "买入"), ("插人", "插入"),
]

# 入 is frequently read as 人; only fix the verb compounds where 人 is impossible.
_VERBS = "进收融纳列投加深入引输流卷步切介植嵌汇打闯侵渗编计归并录导传带走跑陷误落溶划"
for _v in _VERBS:
    RULES.append((_v + "人", _v + "入"))


def fix_text(text: str, enabled: bool = True) -> str:
    """Apply the correction rules to a line or paragraph."""
    if not enabled:
        return text

    for wrong, right in RULES:
        text = text.replace(wrong, right)

    text = re.sub(r"(?<![垂钓])钓(?![鱼竿具友到上])", "的", text)
    for ch in "哟菂旳":
        text = text.replace(ch, "的")
    text = text.replace("劵", "券")

    # AI is often read as AT when surrounded by CJK or quotes.
    text = re.sub(r'(?<=[\u4e00-\u9fa5“”"])AT(?=[\u4e00-\u9fa5“”"])', "AI", text)

    while "的的" in text:
        text = text.replace("的的", "的")
    text = text.replace("。。", "。").replace("……。", "……")
    return text
