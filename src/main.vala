int main (string[] arguments) {
    Intl.setlocale (LocaleCategory.ALL, "");
    Intl.bindtextdomain ("miuutil", MiuUtil.Config.LOCALE_DIR);
    Intl.bind_textdomain_codeset ("miuutil", "UTF-8");
    Intl.textdomain ("miuutil");
    return new MiuUtil.Application ().run (arguments);
}
