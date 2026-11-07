import json
import urllib.request

COUNTRIES_URL = "https://raw.githubusercontent.com/umpirsky/country-list/master/data/en/country.json"
IP_API_URL = "https://ipapi.co/json/"


def get_country():
    try:
        with urllib.request.urlopen(COUNTRIES_URL, timeout=15) as response:
            countries = json.load(response)

        request = urllib.request.Request(
            IP_API_URL,
            headers={"User-Agent": "3x-ui-installer"}
        )

        with urllib.request.urlopen(request, timeout=7) as response:
            data = json.load(response)

        code = data.get("country_code", "").upper()
        name = countries.get(code)

        if not name or len(code) != 2 or not code.isalpha():
            raise ValueError("Country not found")

        flag = "".join(chr(ord(c) + 127397) for c in code)

        return f"{flag} {name}"

    except Exception:
        return "Unknown"


if __name__ == "__main__":
    print(get_country())