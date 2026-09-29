#!/usr/bin/env python3
"""
claude-usage: опрос https://api.anthropic.com/api/oauth/usage токеном Claude Code
и раздача результата с расчётом плана расходования по HTTP в LAN.

Один процесс: фоновый поток опрашивает эндпоинт раз в POLL_SEC, HTTP-сервер отдаёт
/usage.json (полный расчёт) и /raw.json (ответ API как есть).
Только stdlib. Конфиг: config.json рядом со скриптом.
"""
import json, os, sys, time, threading, logging, urllib.request, urllib.error
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
CFG_PATH = os.path.join(HERE, "config.json")
DEFAULT_CFG = {
    "bind": "0.0.0.0",
    "port": 8766,
    "poll_sec": 300,
    "credentials": "~/.claude/.credentials.json",
    "tz": "Europe/Moscow",
    # план: потратить 100 % недельного лимита к (reset - plan_end_offset_hours)
    # сброс сб 07:00 → минус 9 ч = пт 22:00
    "plan_end_offset_hours": 9,
    # «день» для бюджета «доступно сегодня» заканчивается в этот час (локально)
    "day_end_hour": 22,
    # светофор: превышение плана в%
    "yellow_over_pp": 4,
    "red_over_pp": 10,
    # 5-часовое окно
    "session_yellow_pct": 80,
    "session_red_pct": 95,
    "session_window_hours": 5,
    # опережение линейного плана внутри 5-часового окна,%
    "session_yellow_over_pp": 10,
    "session_red_over_pp": 25,
    # данные старше — серый
    "stale_after_sec": 1800,
    "user_agent": "claude-code/2.1.282",
}

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                    stream=sys.stdout)
log = logging.getLogger("claude-usage")

STATE = {"raw": None, "raw_at": None, "error": None, "error_at": None, "http_status": None}
LOCK = threading.Lock()


def load_cfg():
    cfg = dict(DEFAULT_CFG)
    if os.path.exists(CFG_PATH):
        with open(CFG_PATH) as f:
            cfg.update(json.load(f))
    return cfg


def read_token(path):
    with open(os.path.expanduser(path)) as f:
        j = json.load(f)["claudeAiOauth"]
    return j["accessToken"], j.get("expiresAt")


def fetch_usage(cfg):
    token, exp = read_token(cfg["credentials"])
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
            "User-Agent": cfg["user_agent"],
        })
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.status, json.loads(r.read().decode()), exp


def poll_loop(cfg):
    while True:
        try:
            status, data, exp = fetch_usage(cfg)
            with LOCK:
                STATE["raw"] = data
                STATE["raw_at"] = time.time()
                STATE["error"] = None
                STATE["http_status"] = status
                STATE["token_expires_at"] = exp
            log.info("ok: %s", summarize(data))
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")[:300]
            with LOCK:
                STATE["error"] = f"HTTP {e.code}: {body}"
                STATE["error_at"] = time.time()
                STATE["http_status"] = e.code
            log.warning("http error %s %s", e.code, body)
        except Exception as e:  # noqa
            with LOCK:
                STATE["error"] = f"{type(e).__name__}: {e}"
                STATE["error_at"] = time.time()
            log.warning("error: %s", e)
        time.sleep(cfg["poll_sec"])


def summarize(data):
    out = []
    for lim in data.get("limits") or []:
        name = lim.get("kind")
        sc = (lim.get("scope") or {}).get("model") or {}
        if sc.get("display_name"):
            name += ":" + sc["display_name"]
        out.append(f"{name}={lim.get('percent')}%")
    return " ".join(out)


# ---------- расчёт ----------

def parse_ts(s):
    if not s:
        return None
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def extract(data):
    """Возвращает dict: session, weekly_all, weekly_fable (percent, resets_at)."""
    res = {"session": None, "weekly_all": None, "weekly_fable": None, "other_scoped": []}
    lims = data.get("limits")
    if lims:
        for lim in lims:
            item = {"percent": lim.get("percent"), "resets_at": lim.get("resets_at"),
                    "severity": lim.get("severity"), "is_active": lim.get("is_active")}
            kind = lim.get("kind")
            if kind == "session":
                res["session"] = item
            elif kind == "weekly_all":
                res["weekly_all"] = item
            elif kind == "weekly_scoped":
                model = ((lim.get("scope") or {}).get("model") or {}).get("display_name") or "?"
                item["model"] = model
                if model.lower() == "fable":
                    res["weekly_fable"] = item
                else:
                    res["other_scoped"].append(item)
    # запасной путь — старые ключи
    if res["session"] is None and data.get("five_hour"):
        fh = data["five_hour"]
        res["session"] = {"percent": fh.get("utilization"), "resets_at": fh.get("resets_at")}
    if res["weekly_all"] is None and data.get("seven_day"):
        sd = data["seven_day"]
        res["weekly_all"] = {"percent": sd.get("utilization"), "resets_at": sd.get("resets_at")}
    if res["weekly_fable"] is None:
        for k, v in data.items():
            if k.startswith("seven_day_") and isinstance(v, dict) and "fable" in k:
                res["weekly_fable"] = {"percent": v.get("utilization"), "resets_at": v.get("resets_at"), "model": "Fable"}
    return res


def weekly_plan(item, now, cfg, tz):
    """План для недельного счётчика: цель сейчас, дельта, бюджет дня, доступно сегодня."""
    if not item or item.get("percent") is None:
        return None
    reset = parse_ts(item.get("resets_at"))
    if reset is None:
        return None
    used = float(item["percent"])
    start = reset - timedelta(days=7)
    end = reset - timedelta(hours=cfg["plan_end_offset_hours"])
    total_h = (end - start).total_seconds() / 3600
    per_day = 100.0 / (total_h / 24)
    per_hour = 100.0 / total_h

    def target_at(t):
        frac = (t - start).total_seconds() / (end - start).total_seconds()
        return max(0.0, min(100.0, frac * 100.0))

    target_now = target_at(now)
    delta = used - target_now  # >0 — тратим быстрее плана

    # конец «сегодня» по локальному времени
    loc = now.astimezone(tz)
    day_end = loc.replace(hour=cfg["day_end_hour"], minute=0, second=0, microsecond=0)
    if loc >= day_end:
        day_end += timedelta(days=1)
    day_end_utc = day_end.astimezone(timezone.utc)
    target_day_end = target_at(day_end_utc)
    available_today = target_day_end - used  # можно потратить до конца дня, оставаясь в плане
    remaining = 100.0 - used
    hours_to_end = max(0.0, (end - now).total_seconds() / 3600)
    hours_to_reset = max(0.0, (reset - now).total_seconds() / 3600)
    # с какой скоростью надо тратить остаток, чтобы выйти в 100 % к end
    needed_per_day = (remaining / (hours_to_end / 24)) if hours_to_end > 0 else None

    return {
        "used_pct": round(used, 1),
        "remaining_pct": round(remaining, 1),
        "target_now_pct": round(target_now, 1),
        "delta_pp": round(delta, 1),
        "budget_per_day_pp": round(per_day, 2),
        "budget_per_hour_pp": round(per_hour, 3),
        "available_today_pp": round(available_today, 1),
        "day_end_local": day_end.isoformat(),
        "needed_per_day_pp": round(needed_per_day, 2) if needed_per_day is not None else None,
        "plan_start": start.isoformat(),
        "plan_end": end.isoformat(),
        "resets_at": reset.isoformat(),
        "hours_to_plan_end": round(hours_to_end, 1),
        "hours_to_reset": round(hours_to_reset, 1),
    }


def session_plan(item, now, cfg):
    """5-часовое окно: план — линейно потратить 100 % от начала окна до сброса."""
    if not item or item.get("percent") is None:
        return None
    used = float(item["percent"])
    reset = parse_ts(item.get("resets_at"))
    win_h = float(cfg.get("session_window_hours", 5))
    out = {"used_pct": round(used, 1), "remaining_pct": round(100.0 - used, 1),
           "available_pct": round(100.0 - used, 1),
           "resets_at": reset.isoformat() if reset else None,
           "minutes_to_reset": None, "target_now_pct": None, "delta_pp": None,
           "available_now_pp": None, "active": False}
    if reset is None or reset <= now:
        out["active"] = False
        return out
    start = reset - timedelta(hours=win_h)
    mins = (reset - now).total_seconds() / 60
    frac = max(0.0, min(1.0, (now - start).total_seconds() / (win_h * 3600)))
    target = frac * 100.0
    out.update({
        "active": True,
        "window_start": start.isoformat(),
        "minutes_to_reset": round(mins),
        "minutes_elapsed": round(win_h * 60 - mins),
        "target_now_pct": round(target, 1),
        "delta_pp": round(used - target, 1),          # >0 — быстрее плана
        "available_now_pp": round(target - used, 1),  # можно потратить прямо сейчас, оставаясь в плане
        "needed_per_hour_pp": round((100.0 - used) / (mins / 60), 1) if mins > 1 else None,
    })
    return out


def color_session(sess, cfg):
    if not sess or not sess.get("active"):
        return "green", "окно не начато"
    u = sess["used_pct"]; d = sess["delta_pp"]
    if u >= 100:
        return "red", "5ч окно исчерпано"
    if u >= cfg["session_red_pct"] or d > cfg["session_red_over_pp"]:
        return "red", f"5ч окно {u:.0f}% ({d:+.0f}% к плану)"
    if u >= cfg["session_yellow_pct"] or d > cfg["session_yellow_over_pp"]:
        return "yellow", f"5ч окно {u:.0f}% ({d:+.0f}% к плану)"
    return "green", f"5ч окно в плане ({d:+.0f}%)"


def color_weekly(fable, weekly, cfg):
    reasons = []; level = 0
    for name, p in (("Fable", fable), ("Неделя", weekly)):
        if not p:
            continue
        d = p["delta_pp"]
        if p["used_pct"] >= 100:
            level = 2; reasons.append(f"{name} исчерпан")
        elif d > cfg["red_over_pp"]:
            level = max(level, 2); reasons.append(f"{name} +{d:.0f}% к плану")
        elif d > cfg["yellow_over_pp"]:
            level = max(level, 1); reasons.append(f"{name} +{d:.0f}% к плану")
    return ["green", "yellow", "red"][level], ("; ".join(reasons) or "в плане")


def build(cfg):
    tz = ZoneInfo(cfg["tz"])
    now = datetime.now(timezone.utc)
    with LOCK:
        raw = STATE["raw"]; raw_at = STATE["raw_at"]; err = STATE["error"]; err_at = STATE["error_at"]
        tok_exp = STATE.get("token_expires_at")
    age = (time.time() - raw_at) if raw_at else None
    stale = raw is None or age > cfg["stale_after_sec"]
    out = {
        "generated_at": now.isoformat(),
        "generated_local": now.astimezone(tz).isoformat(),
        "data_at": datetime.fromtimestamp(raw_at, timezone.utc).isoformat() if raw_at else None,
        "data_age_sec": round(age) if age is not None else None,
        "stale": stale,
        "error": err,
        "error_at": datetime.fromtimestamp(err_at, timezone.utc).isoformat() if err_at else None,
        "token_expires_at": datetime.fromtimestamp(tok_exp / 1000, timezone.utc).isoformat() if tok_exp else None,
        "config": {k: cfg[k] for k in ("plan_end_offset_hours", "day_end_hour", "yellow_over_pp",
                                       "red_over_pp", "session_yellow_pct", "session_red_pct",
                                       "session_yellow_over_pp", "session_red_over_pp", "session_window_hours", "tz")},
    }
    if raw:
        ex = extract(raw)
        fable = weekly_plan(ex["weekly_fable"], now, cfg, tz)
        weekly = weekly_plan(ex["weekly_all"], now, cfg, tz)
        sess = session_plan(ex["session"], now, cfg)
        if stale:
            cw, rw = "gray", "нет свежих данных"; cs, rs = "gray", "нет свежих данных"
        else:
            cw, rw = color_weekly(None, weekly, cfg)   # только общий недельный лимит
            cs, rs = color_session(sess, cfg)
        color = "red" if "red" in (cw, cs) else ("yellow" if "yellow" in (cw, cs) else cw)
        out.update({
            "color": color, "reason": "; ".join(x for x in (rw, rs) if x),
            "color_weekly": cw, "reason_weekly": rw,
            "color_session": cs, "reason_session": rs,
            "fable": fable, "weekly": weekly, "session": sess,
            "other_scoped": ex["other_scoped"],
            "breakdown": (raw.get("seven_day_breakdown") or {}).get("rows"),
            "extra_usage_enabled": (raw.get("extra_usage") or {}).get("is_enabled"),
        })
    else:
        out.update({"color": "gray", "reason": err or "ещё нет данных",
                    "color_weekly": "gray", "color_session": "gray"})
    return out


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # тише
        pass

    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False, indent=1).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        cfg = load_cfg()
        if self.path in ("/", "/usage.json"):
            self._send(200, build(cfg))
        elif self.path == "/raw.json":
            with LOCK:
                self._send(200, STATE["raw"] or {"error": STATE["error"]})
        elif self.path == "/health":
            with LOCK:
                ok = STATE["raw"] is not None
            self._send(200 if ok else 503, {"ok": ok, "error": STATE["error"]})
        else:
            self._send(404, {"error": "not found"})


def main():
    cfg = load_cfg()
    t = threading.Thread(target=poll_loop, args=(cfg,), daemon=True)
    t.start()
    srv = ThreadingHTTPServer((cfg["bind"], cfg["port"]), H)
    log.info("listening on %s:%s, poll every %ss", cfg["bind"], cfg["port"], cfg["poll_sec"])
    srv.serve_forever()


if __name__ == "__main__":
    main()
