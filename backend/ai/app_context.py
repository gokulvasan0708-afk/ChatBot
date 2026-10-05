"""System prompt builder: rules + app data retrieved for THIS question.

In services/openrouter_service.py:
    from app_context import build_system_prompt
    messages = [{"role": "system", "content": build_system_prompt(message)},
                {"role": "user", "content": message}]
"""
try:
    from knowledge.retriever import retrieve
except Exception:  # missing JSON etc. -> static fallback below
    retrieve = None

RULES = """You are the in-app assistant of Nexus, a Flutter chat and community app (Chats, Hubs = community with groups/clubs/events/polls/resources/announcements, voice/video calls, notifications, Me = profile and settings). Help users use the app.
- For app questions, use ONLY the APP DATA below (taken from the app's source code). Describe where to tap using page names, 'texts' (real button/label text) and 'reached from'. Never invent buttons or features; if the data doesn't cover it, say you're not sure.
- Page/file names are for you; tell users the screen title or button text, not class names or file paths.
- Parts marked admin-only are for group/club/community admins or moderators only.
- You cannot see the user's chats, contacts or account data. Never ask for passwords, OTPs or tokens.
- Do not mention or pretend to be any other app.
- Reply in the user's language (Tamil in English letters is fine). Short, friendly. Light formatting only: **bold** and '- ' bullets."""

FALLBACK = """APP DATA: Bottom nav: Chats, Hubs (community), Me. Get started / Login; Chats (private chats, groups, connect requests, calls); Hubs (groups, clubs, events, polls, resources, announcements, notice board, members); Me (profile, settings, dark/light mode, notifications)."""


def build_system_prompt(user_message: str) -> str:
    try:
        ctx = retrieve(user_message) if retrieve else FALLBACK
    except Exception:
        ctx = FALLBACK
    return f"{RULES}\n\nAPP DATA:\n{ctx}"
