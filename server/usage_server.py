#!/usr/bin/env python3
"""
claude-usage: опрос https://api.anthropic.com/api/oauth/usage токеном Claude Code
и раздача результата с расчётом плана расходования по HTTP в LAN.

Один процесс: фоновый поток опрашивает эндпоинт раз в POLL_SEC, HTTP-сервер отдаёт
/usage.json (полный расчёт) и /raw.json (ответ API как есть).
Истёкший токен сервер продлевает сам по refresh-токену и пишет обратно в файл Claude Code
(auto_refresh); после отказов API делает паузы с удвоением до max_backoff_sec.
Только stdlib. Конфиг: config.json рядом со скриптом.
"""
import json, os, re, sys, time, threading, logging, tempfile, contextlib, email.utils, urllib.request, urllib.error
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
    # истёкший токен продлевать самому (refresh-токен одноразовый: см. refresh_token)
    "auto_refresh": True,
    # после отказа API пауза poll_sec, дальше вдвое дольше на каждый отказ подряд, но не больше этого
    "max_backoff_sec": 1800,
}

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                    stream=sys.stdout)
log = logging.getLogger("claude-usage")

# снимок недельного расхода на начало суток — чтобы показать «потрачено сегодня»
DAY = {"date": None, "start": None, "since": None}
DAY_PATH = os.path.join(HERE, "state.json")


def load_day():
    try:
        with open(DAY_PATH) as f:
            DAY.update(json.load(f))
    except Exception:
        pass


def update_day(data, cfg):
    w = extract(data)["weekly_all"]
    if not w or w.get("percent") is None:
        return
    used = float(w["percent"])
    now = datetime.now(ZoneInfo(cfg["tz"]))
    today = now.date().isoformat()
    if DAY["date"] != today or DAY["start"] is None:
        DAY.update(date=today, start=used, since=now.isoformat())
    elif used < float(DAY["start"]):          # недельный сброс посреди дня — считаем от нуля
        DAY.update(start=0.0, since=now.isoformat())
    try:
        with open(DAY_PATH, "w") as f:
            json.dump(DAY, f)
    except Exception:
        pass


STATE = {"raw": None, "raw_at": None, "error": None, "error_at": None, "http_status": None,
         "fails": 0, "next_poll_at": None}
LOCK = threading.Lock()


def load_cfg():
    cfg = dict(DEFAULT_CFG)
    if os.path.exists(CFG_PATH):
        with open(CFG_PATH, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("config.json is not a JSON object")
        cfg.update(data)
    return cfg


# допустимые пределы: значение вне их прижимается к границе (poll_sec 1e-9 — это шквал запросов к Anthropic,
# day_end_hour 24 или session_window_hours 0 ломают расчёт плана); CFG_INT — только целые (час, порт)
CFG_LIMITS = {"poll_sec": (30, 86400), "max_backoff_sec": (0, 7 * 86400), "stale_after_sec": (60, 7 * 86400),
              "day_end_hour": (0, 23), "port": (0, 65535), "plan_end_offset_hours": (0, 160),
              "session_window_hours": (0.5, 24)}
CFG_INT = ("day_end_hour", "port")


def valid_tz(v):
    try:
        ZoneInfo(v)
        return True
    except Exception:  # noqa
        return False


def check_cfg(cfg, prev, quiet=False):
    """Каждый ключ — своего типа (число, да/нет, строка, часовой пояс); негодный заменяется прежним значением,
    число вне CFG_LIMITS прижимается к границе. Остальные ключи файла действуют."""
    for k, d in DEFAULT_CFG.items():
        v = cfg.get(k)
        if isinstance(d, bool):
            ok = isinstance(v, bool)
        elif isinstance(d, (int, float)):
            ok = isinstance(v, (int, float)) and not isinstance(v, bool) and v == v      # число, не NaN
            if ok and k in CFG_INT:
                ok = abs(v) != float("inf") and v == int(v)                               # 21.5 часа не бывает
        elif k == "tz":
            ok = isinstance(v, str) and valid_tz(v)
        else:
            ok = isinstance(v, str)
        if not ok:
            if not quiet:
                log.warning("config.json: bad %s = %r, using %r", k, v, prev.get(k, d))
            cfg[k] = prev.get(k, d)
    for k, (lo, hi) in CFG_LIMITS.items():
        if not lo <= cfg[k] <= hi:
            if not quiet:
                log.warning("config.json: %s = %r is outside %s..%s, clamped", k, cfg[k], lo, hi)
            cfg[k] = min(max(cfg[k], lo), hi)
    for k in CFG_INT:
        cfg[k] = int(cfg[k])
    return cfg


def poll_cfg(prev, quiet=False):
    """Конфиг для очередного опроса или запроса: config.json перечитывается каждый раз (правки — без перезапуска).
    Нечитаемый файл (например, недописанный при правке) — остаются прежние настройки целиком."""
    try:
        cfg = load_cfg()
    except Exception as e:  # noqa
        if not quiet:
            log.warning("config.json not readable, keeping previous settings: %s", e)
        return prev
    return check_cfg(cfg, prev, quiet)


USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"      # client_id Claude Code
RETRY_AFTER_MAX = 6 * 3600   # Retry-After длиннее — скорее мусор (дата в далёком будущем): дольше не ждём

# Продлённые токены, которые не удалось записать в файл (диск полон и т.п.). Старый refresh-токен к этому
# моменту уже потрачен, так что действительны только они: работаем с ними и на каждом опросе пробуем записать.
PENDING = None          # claudeAiOauth с новыми токенами
PENDING_SPENT = None    # refresh-токен, потраченный на их получение
# Токен, полученный продлением после 401: если API отвечает 401 и ему, продлевать снова бесполезно.
MINTED_ON_401 = None


class RefreshError(Exception):
    """Продлить токен не удалось. code — HTTP-статус (None: сеть, таймаут, формат ответа, файл)."""
    def __init__(self, msg, code=None, retry_after=None):
        super().__init__(msg)
        self.code = code
        self.retry_after = retry_after


class TokenExpired(Exception):
    """Токен истёк, а auto_refresh выключен: ждём, пока его продлит сам Claude Code."""


def compact(s, n=300):
    return " ".join(s.split())[:n]                      # тело ответа одной строкой — для лога и поля error


def http_body(e):
    """Тело HTTP-ошибки одной строкой. Чтение может оборваться (таймаут, разрыв) — тогда пусто: код уже известен."""
    try:
        return compact(e.read().decode(errors="replace"))
    except Exception:  # noqa
        return ""
    finally:
        with contextlib.suppress(Exception):
            e.close()


def retry_after(e):
    return (e.headers or {}).get("Retry-After")


def read_creds(path):
    with open(os.path.expanduser(path), encoding="utf-8") as f:
        return json.load(f)


def creds_path(cfg):
    return os.path.realpath(os.path.expanduser(cfg["credentials"]))   # симлинк не затираем обычным файлом


def expired(exp, margin_sec=60):
    return bool(exp) and exp < (time.time() + margin_sec) * 1000


def write_all(fd, data):
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view):]


def reserve_tmp(path, j):
    """Временный файл рядом с кредами (0600), заранее заполненный текущим JSON с запасом места: если в папку
    нельзя писать или диск полон, это выяснится сейчас, пока refresh-токен ещё не потрачен."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".credentials.", suffix=".tmp")
    try:
        write_all(fd, (json.dumps(j, separators=(",", ":")) + " " * 4096).encode())
        os.fsync(fd)
    except BaseException:
        discard_tmp((fd, tmp))
        raise
    return fd, tmp


def discard_tmp(prepared):
    fd, tmp = prepared
    with contextlib.suppress(OSError):
        os.close(fd)
    with contextlib.suppress(OSError):
        os.unlink(tmp)


def write_creds(path, new, prepared=None, base=None):
    """Записать продлённые accessToken/refreshToken/expiresAt. Файл перечитывается прямо перед записью
    (Claude Code мог поменять в нём другое, например токены MCP), остальные поля остаются как в нём;
    не перечитался — берём base (снимок до продления). Запись — во временный файл той же папки, fsync, os.replace."""
    try:
        j = read_creds(path)
        if not isinstance(j, dict):
            raise ValueError("not a JSON object")
    except Exception:  # noqa — файл пропал или битый
        j = json.loads(json.dumps(base)) if isinstance(base, dict) else {}
    o = j.get("claudeAiOauth")
    if isinstance(o, dict) and o:
        o.update({k: new[k] for k in ("accessToken", "refreshToken", "expiresAt") if k in new})
    else:
        j["claudeAiOauth"] = dict(new)
    data = json.dumps(j, separators=(",", ":")).encode()
    fd, tmp = prepared or tempfile.mkstemp(dir=os.path.dirname(path), prefix=".credentials.", suffix=".tmp")
    try:
        os.lseek(fd, 0, os.SEEK_SET)
        write_all(fd, data)
        os.ftruncate(fd, len(data))
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.replace(tmp, path)
    except BaseException:
        if fd is not None:
            with contextlib.suppress(OSError):
                os.close(fd)
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def save_pending(cfg):
    """Повторить запись продлённых токенов, которые раньше записать не удалось."""
    global PENDING, PENDING_SPENT
    path = creds_path(cfg)
    try:
        cur = read_creds(path).get("claudeAiOauth") or {}
    except FileNotFoundError:
        cur = {}
    except Exception as e:  # noqa — файл сейчас пишет Claude Code или он битый: не затирать, попробуем на следующем опросе
        log.warning("credentials file not readable (%s); will retry writing the refreshed tokens", e)
        return
    rt = cur.get("refreshToken")
    if rt and rt not in (PENDING_SPENT, PENDING.get("refreshToken")):
        # в файле новая цепочка (например, вход в Claude Code заново) — она главнее наших токенов
        log.warning("credentials file has new tokens; dropping the unsaved refreshed ones")
        PENDING = PENDING_SPENT = None
        return
    try:
        write_creds(path, PENDING)
    except Exception as e:  # noqa
        log.error("credentials file still not written (%s); using the refreshed tokens from memory", e)
        return
    log.info("refreshed tokens written to %s", path)
    PENDING = PENDING_SPENT = None


def current_token(cfg):
    """Access-токен и срок: из незаписанного продления, иначе из файла Claude Code."""
    if PENDING:
        save_pending(cfg)
    if PENDING:
        return PENDING["accessToken"], PENDING.get("expiresAt")
    o = read_creds(creds_path(cfg))["claudeAiOauth"]
    return o["accessToken"], o.get("expiresAt")


def refresh_token(cfg, rejected=None):
    """Продлить access-токен по refresh-токену и записать обратно в файл Claude Code.

    Refresh-токен одноразовый: если тем временем на этой машине работает Claude Code со старым в памяти,
    он может попросить войти заново. Поэтому, как и автономный режим виджета, продлеваем только уже истёкший
    токен (или тот, на который API только что ответил 401, — rejected), а файл перечитываем прямо перед
    запросом: вдруг Claude Code уже продлил сам. Если новые токены не удалось записать, они остаются в памяти
    (PENDING) — без них Claude Code на этой машине пришлось бы входить заново.
    """
    global PENDING, PENDING_SPENT
    path = creds_path(cfg)
    j = {"claudeAiOauth": PENDING} if PENDING else read_creds(path)
    o = j.get("claudeAiOauth") or {}
    if o.get("accessToken") != rejected and not expired(o.get("expiresAt")):
        return o["accessToken"], o.get("expiresAt")      # Claude Code успел продлить сам
    spent = o.get("refreshToken")
    if not spent:
        raise RefreshError("token refresh: no refreshToken in the credentials file (sign in to Claude Code again)")
    try:
        prepared = reserve_tmp(path, j)
    except OSError as e:
        raise RefreshError(f"token refresh skipped: cannot write next to {path}: {e}") from None
    try:
        body = json.dumps({"grant_type": "refresh_token", "refresh_token": spent,
                           "client_id": CLIENT_ID, "scope": " ".join(o.get("scopes") or [])}).encode()
        req = urllib.request.Request(TOKEN_URL, data=body, method="POST",
                                     headers={"Content-Type": "application/json", "User-Agent": cfg["user_agent"]})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                resp = json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            raise RefreshError(f"token refresh HTTP {e.code}: {http_body(e)}", e.code, retry_after(e)) from None
        except Exception as e:  # noqa — сеть, таймаут, не-JSON
            raise RefreshError(f"token refresh: {type(e).__name__}: {e}") from None
        if not isinstance(resp, dict) or not resp.get("access_token"):
            raise RefreshError("token refresh: no access_token in the response")
    except BaseException:
        discard_tmp(prepared)
        raise
    new = dict(o)
    new["accessToken"] = resp["access_token"]
    if resp.get("refresh_token"):
        new["refreshToken"] = resp["refresh_token"]
    try:
        expires_in = min(max(int(resp.get("expires_in") or 3600), 60), 30 * 86400)
    except (TypeError, ValueError, OverflowError):
        expires_in = 3600
    new["expiresAt"] = int((time.time() + expires_in) * 1000)
    try:
        write_creds(path, new, prepared, base=j)
        PENDING = PENDING_SPENT = None
    except Exception as e:  # noqa
        PENDING, PENDING_SPENT = new, (PENDING_SPENT if PENDING_SPENT else spent)
        log.error("token refreshed but %s not written (%s): keeping the new tokens in memory, will retry", path, e)
    log.info("token refreshed, expires in %ss", expires_in)
    return new["accessToken"], new["expiresAt"]


def call_usage(token, cfg):
    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
            "User-Agent": cfg["user_agent"],
        })
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.status, json.loads(r.read().decode())


def fetch_usage(cfg):
    global MINTED_ON_401
    token, exp = current_token(cfg)
    auto = cfg.get("auto_refresh", True)
    refreshed = False
    if expired(exp):
        if not auto:     # запрос с мёртвым токеном бесполезен, а частые 401 Anthropic наказывает 429
            at = datetime.fromtimestamp(exp / 1000, ZoneInfo(cfg["tz"])).isoformat(timespec="minutes")
            raise TokenExpired(f"token expired at {at}, auto_refresh is off: waiting for Claude Code to refresh it")
        token, exp = refresh_token(cfg)
        refreshed = True
    try:
        status, data = call_usage(token, cfg)
        if token == MINTED_ON_401:
            MINTED_ON_401 = None   # токен заработал: если его потом отзовут, одно продление по 401 снова допустимо
    except urllib.error.HTTPError as e:
        # 401 на токен, живой по часам (отозван или продлён другим процессом): перечитать файл и при нужде
        # продлить — но не больше раза на токен; если 401 получает и продлённый, ждём с паузой, как после отказа
        if e.code != 401 or not auto or refreshed or token == MINTED_ON_401:
            raise
        http_body(e)
        log.warning("usage HTTP 401, refreshing the token")
        try:
            token, exp = refresh_token(cfg, rejected=token)
        except RefreshError as r:
            if r.code is None:   # usage этому токену уже отказал: это отказ API, пауза растёт; в тексте — код 401
                msg = str(r).removeprefix("token refresh: ")
                raise RefreshError(f"token refresh failed after usage HTTP 401: {msg}", 401, r.retry_after) from None
            raise
        MINTED_ON_401 = token
        status, data = call_usage(token, cfg)
    return status, data, exp


def retry_after_sec(v):
    """Retry-After: секунды или HTTP-дата; None — нет или не разобрать."""
    if not v:
        return None
    try:
        return float(v)
    except ValueError:
        pass
    try:
        return (email.utils.parsedate_to_datetime(v) - datetime.now(timezone.utc)).total_seconds()
    except Exception:  # noqa — дата без пояса, мусор
        return None


def backoff(cfg, fails, retry_after=None):
    """Пауза после отказа API: poll_sec, дальше вдвое дольше на каждый отказ подряд, не больше max_backoff_sec.
    Retry-After от сервера — нижняя граница: может продлить паузу и сверх max_backoff_sec, но не больше 6 ч."""
    cap = max(cfg["poll_sec"], cfg["max_backoff_sec"])
    d = min(cfg["poll_sec"] * 2 ** min(fails - 1, 20), cap)
    ra = retry_after_sec(retry_after)
    if ra and ra > 0:
        d = max(d, min(ra, RETRY_AFTER_MAX))
    return d


def record_error(msg, code, fails):
    with LOCK:
        STATE["error"] = msg
        STATE["error_at"] = time.time()
        STATE["http_status"] = code
        STATE["fails"] = fails


LAST_CFG = dict(DEFAULT_CFG)     # последний принятый конфиг — запасной и для HTTP-запросов, если файл не читается


def poll_loop(cfg=None):
    global LAST_CFG
    cfg = cfg or dict(DEFAULT_CFG)
    fails = 0                     # отказов API подряд (HTTP-ошибки) — от них растёт пауза
    while True:
        cfg = LAST_CFG = poll_cfg(cfg)
        delay = cfg["poll_sec"]
        try:
            try:
                status, data, exp = fetch_usage(cfg)
                fails = 0
                with LOCK:
                    STATE["raw"] = data
                    STATE["raw_at"] = time.time()
                    STATE["error"] = None
                    STATE["http_status"] = status
                    STATE["token_expires_at"] = exp
                    STATE["fails"] = 0
                update_day(data, cfg)
                log.info("ok: %s", summarize(data))
            except urllib.error.HTTPError as e:
                body = http_body(e)
                fails += 1
                delay = backoff(cfg, fails, retry_after(e))
                record_error(f"HTTP {e.code}: {body}", e.code, fails)
                log.warning("http error %s %s; next try in %ds", e.code, body, delay)
            except RefreshError as e:
                if e.code:        # отказ эндпоинта продления — тоже пауза с удвоением; сеть — обычный интервал
                    fails += 1
                    delay = backoff(cfg, fails, e.retry_after)
                record_error(str(e), e.code, fails)
                log.warning("%s; next try in %ds", e, delay)
            except Exception as e:  # noqa — сеть, файл токена, TokenExpired: в Anthropic не дошло, интервал обычный
                record_error(f"{type(e).__name__}: {e}", None, fails)
                log.warning("error: %s; next try in %ds", e, delay)
        except Exception as e:  # noqa — что бы ни случилось и в обработке ошибки, поток опроса не должен умереть
            log.exception("poll loop: %s", e)
            delay = cfg["poll_sec"]
        with LOCK:
            STATE["next_poll_at"] = time.time() + delay
        time.sleep(delay)


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
        tok_exp = STATE.get("token_expires_at"); next_at = STATE.get("next_poll_at"); fails = STATE.get("fails", 0)
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
        "next_poll_at": datetime.fromtimestamp(next_at, timezone.utc).isoformat() if next_at else None,
        "consecutive_errors": fails,
        "config": {k: cfg[k] for k in ("plan_end_offset_hours", "day_end_hour", "yellow_over_pp",
                                       "red_over_pp", "session_yellow_pct", "session_red_pct",
                                       "session_yellow_over_pp", "session_red_over_pp", "session_window_hours", "tz")},
    }
    if raw:
        ex = extract(raw)
        fable = weekly_plan(ex["weekly_fable"], now, cfg, tz)
        weekly = weekly_plan(ex["weekly_all"], now, cfg, tz)
        sess = session_plan(ex["session"], now, cfg)
        if weekly and DAY["date"] == now.astimezone(tz).date().isoformat() and DAY["start"] is not None:
            weekly["spent_today_pp"] = round(weekly["used_pct"] - float(DAY["start"]), 1)
            weekly["today_since"] = DAY["since"]
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
        try:
            if self.path in ("/", "/usage.json"):
                self._send(200, build(poll_cfg(LAST_CFG, quiet=True)))   # пороги — свежие из файла, битый — прежние
            elif self.path == "/raw.json":
                with LOCK:
                    obj = STATE["raw"] or {"error": STATE["error"]}
                self._send(200, obj)
            elif self.path == "/health":
                with LOCK:
                    ok = STATE["raw"] is not None
                    err = STATE["error"]
                self._send(200 if ok else 503, {"ok": ok, "error": err})
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:  # noqa — ответить ошибкой, а не обрывом соединения (виджет решил бы, что сервер недоступен)
            log.warning("request %s: %s: %s", self.path, type(e).__name__, e)
            with contextlib.suppress(Exception):
                self._send(500, {"error": f"{type(e).__name__}: {e}"})


def cleanup_tmp(cfg):
    """Временные файлы с токенами, оставшиеся от продления, прерванного убийством процесса (имена — от mkstemp)."""
    try:
        d = os.path.dirname(creds_path(cfg))
        for name in os.listdir(d):
            p = os.path.join(d, name)
            if re.fullmatch(r"\.credentials\.[a-z0-9_]{8}\.tmp", name) and time.time() - os.path.getmtime(p) > 600:
                os.unlink(p)
                log.info("removed stale %s", p)
    except Exception as e:  # noqa
        log.warning("stale tmp cleanup: %s", e)


def main():
    global LAST_CFG
    cfg = LAST_CFG = poll_cfg(dict(DEFAULT_CFG))
    load_day()
    cleanup_tmp(cfg)
    t = threading.Thread(target=poll_loop, args=(cfg,), daemon=True)
    t.start()
    srv = ThreadingHTTPServer((cfg["bind"], cfg["port"]), H)
    log.info("listening on %s:%s, poll every %ss", cfg["bind"], cfg["port"], cfg["poll_sec"])
    srv.serve_forever()


if __name__ == "__main__":
    main()
