import re

import tomllib

LANG_FILE = "lang.toml"

# todo: escape special characters?
with open(LANG_FILE, "rb") as file:
	lang_dict = tomllib.load(file)


def tr(key, lang):
	"""
	returns the string for the key in the given language
	throws exceptions if the key is not found, or doesn't have a
	value for lang nor "en"
	"""

	k = lang_dict.get(key)
	if k is None:
		raise Exception("Unknown translation key '" + key + "'")
	l = k.get(lang)
	if k is None:
		print(
			"Missing lang '"
			+ lang
			+ "' for translation key '"
			+ key
			+ "'. Defaulting to english."
		)
		e = k.get(english)
		if e is None:
			raise Exception("Missing english (en) for translation key '" + key + "'")
		else:
			return e

	return l


def tr_template(text, lang):
	"""
	replaces any fragment of the format
	{{ KEY }} with the value for that key in
	the given language
	"""

	def rep(key):
		return tr(key.group(1), lang)

	return re.sub(r"\{\{ *([0-9a-zA-Z_]+) *\}\}", rep, text)
