#!/usr/bin/env python3
"""校验 workflow：数据不进 run 插值，且步骤顺序符合准入→生成→发布→锁定的契约。"""
import io, re, sys, yaml

PATH = ".github/workflows/ai-reply.yml"
doc = yaml.safe_load(io.open(PATH, encoding="utf-8"))
steps = doc["jobs"]["ai-reply"]["steps"]
names = [s.get("name", "?") for s in steps]
problems = []

for s in steps:
    for expr in re.findall(r"\$\{\{[^}]*\}\}", s.get("run", "")):
        if "runner.temp" not in expr.lower():
            problems.append(f"{s.get('name')} 的 run 里插值了 {expr}")

def idx(name):
    return names.index(name) if name in names else None

required = ["准入判定", "装配历史上下文", "生成倾听回复", "评论回复", "回复成功后再锁定"]
missing = [n for n in required if idx(n) is None]
if missing:
    problems.append("缺少步骤：" + ", ".join(missing))
else:
    if not idx("准入判定") < idx("装配历史上下文"):
        problems.append("准入判定必须在装配之前")
    if not idx("评论回复") < idx("回复成功后再锁定"):
        problems.append("锁定必须在回复成功之后，否则被拒的人会失去补救入口")

by_name = {s.get("name"): s for s in steps}
gen = by_name.get("生成倾听回复", {})
if gen.get("continue-on-error"):
    problems.append("生成步骤不能继续容错，否则模型调用失败会被记成 success")
admit = by_name.get("准入判定", {})
if not admit.get("continue-on-error"):
    problems.append("准入步骤必须容错，拒绝是正常分支不该让 job 变红")

print("步骤数:", len(steps))
print("YAML 解析: OK")
for p in problems:
    print("  ✗", p)
sys.exit(1 if problems else 0)
