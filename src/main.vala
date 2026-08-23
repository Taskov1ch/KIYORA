/* 
 * Copyright 2022 Nanling
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

int main (string[] args) {
    Environment.set_prgname (Config.APP_ID);
    Intl.setlocale (LocaleCategory.ALL, "");
    apply_preferred_language ();

    Intl.bindtextdomain (Config.CODE_NAME, get_locale_dir (args[0]));
    Intl.bind_textdomain_codeset (Config.CODE_NAME, "UTF-8");
    Intl.textdomain (Config.CODE_NAME);

    Environment.set_application_name ("KIYORA");
    fix_gst_tag_encoding ();

    Random.set_seed ((uint32) get_monotonic_time ());

    G4.GstPlayer.init (ref args);

    var app = new G4.Application ();
    return app.run (args);
}

string get_locale_dir (string command) {
    var executable = command.contains (Path.DIR_SEPARATOR_S)
        ? Filename.canonicalize (command)
        : Environment.find_program_in_path (command);
    if (executable == null)
        return Config.LOCALEDIR;

    var build_root = Path.get_dirname (Path.get_dirname ((!)executable));
    var build_locale_dir = Path.build_filename (build_root, "po");
    var meson_private_dir = Path.build_filename (build_root, "meson-private");
    if (FileUtils.test (meson_private_dir, FileTest.IS_DIR)
        && FileUtils.test (build_locale_dir, FileTest.IS_DIR))
        return build_locale_dir;

    return Config.LOCALEDIR;
}

void apply_preferred_language () {
    var settings = new Settings (Config.APP_ID);
    var language = settings.get_string ("language");
    if (language.length == 0)
        return;

    Environment.set_variable ("LANGUAGE", language, true);

    // GNU gettext ignores LANGUAGE while LC_MESSAGES uses the C locale.
    var messages_locale = Intl.setlocale (LocaleCategory.MESSAGES, null) ?? "C";
    if (messages_locale == "C" || messages_locale == "POSIX" || messages_locale.has_prefix ("C.")) {
        var system_locale = Environment.get_variable ("LANG") ?? "en_US.UTF-8";
        if (Intl.setlocale (LocaleCategory.MESSAGES, system_locale) == null)
            Intl.setlocale (LocaleCategory.MESSAGES, "en_US.UTF-8");
    }
}

void fix_gst_tag_encoding () {
    unowned var encoding = Environment.get_variable ("GST_TAG_ENCODING");
    unowned var lang = Environment.get_variable ("LANG");
    if (encoding == null && lang != null) {
        string[] lang_encodings = {
            "ja", "Shift_JIS",
            "ko", "EUC-KR",
            "zh_CN", "GB18030",
            "zh_HK", "BIG5HKSCS",
            "zh_SG", "GB2312",
            "zh_TW", "BIG5",
        };
        for (var i = 0; i < lang_encodings.length; i += 2) {
            if (((!)lang).has_prefix (lang_encodings[i])) {
                Environment.set_variable ("GST_TAG_ENCODING", lang_encodings[i + 1], true);
                print ("Fix tag encoding: %s\n", lang_encodings[i + 1]);
                break;
            }
        }
    }
}
