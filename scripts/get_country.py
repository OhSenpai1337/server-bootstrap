import json
import urllib.request

IP_API_URL = "https://ipwho.is/"


def get_country():
    try:
        request = urllib.request.Request(
            IP_API_URL,
            headers={"User-Agent": "3x-ui-installer"}
        )

        with urllib.request.urlopen(request, timeout=10) as response:
            data = json.load(response)

        if not data.get("success"):
            return "Unknown"

        code = data.get("country_code", "").upper()
        name = data.get("country")

        if not name or len(code) != 2 or not code.isalpha():
            return "Unknown"

        flag = "".join(chr(ord(c) + 127397) for c in code)

        return f"{flag} {name}"

    except Exception:
        return "Unknown"


if __name__ == "__main__":
    print(get_country())