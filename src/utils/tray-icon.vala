namespace G4 {

    [DBus (name = "org.kde.StatusNotifierWatcher")]
    public interface StatusNotifierWatcher : GLib.Object {
        public abstract void register_status_notifier_item (string service) throws GLib.Error;
    }

    [DBus (name = "org.kde.StatusNotifierItem")]
    public class StatusNotifierItemImpl : GLib.Object {
        [DBus (visible = false)]
        private unowned Application _app;
        [DBus (visible = false)]
        private unowned TrayIcon _tray;

        public StatusNotifierItemImpl (Application app, TrayIcon tray) {
            _app = app;
            _tray = tray;
        }

        public string category { owned get { return "ApplicationStatus"; } }
        public string id { owned get { return Config.APP_ID; } }
        public string title { owned get { return _app.name; } }
        public string status { owned get { return "Active"; } }
        public int window_id { get { return 0; } }
        public string icon_theme_path { owned get { return _tray.icon_theme_path; } }
        public ObjectPath menu { owned get { return new ObjectPath ("/MenuBar"); } }
        public bool item_is_menu { get { return false; } }
        public string icon_name { owned get { return Config.APP_ID + "-symbolic"; } }
        public Variant icon_pixmap { owned get { return _tray.icon_pixmap; } }
        public string overlay_icon_name { owned get { return ""; } }
        public Variant overlay_icon_pixmap { owned get { return new Variant.array (new VariantType ("(iiay)"), {}); } }
        public string attention_icon_name { owned get { return ""; } }
        public Variant attention_icon_pixmap { owned get { return new Variant.array (new VariantType ("(iiay)"), {}); } }
        public string attention_movie_name { owned get { return ""; } }
        public Variant tool_tip { owned get { return _tray.build_tool_tip (); } }

        public signal void new_title ();
        public signal void new_icon ();
        public signal void new_attention_icon ();
        public signal void new_overlay_icon ();
        public signal void new_tool_tip ();
        public signal void new_status (string status);
        public signal void new_menu ();

        public void context_menu (int x, int y) throws GLib.Error {
            // Context menu is served via DBusMenu at /MenuBar
        }

        public void activate (int x, int y) throws GLib.Error {
            _app.present_window ();
        }

        public void secondary_activate (int x, int y) throws GLib.Error {
            _app.play_pause ();
        }

        public void scroll (int delta, string orientation) throws GLib.Error {
            double diff = delta > 0 ? 0.05 : -0.05;
            _app.player.volume = (_app.player.volume + diff).clamp (0.0, 1.0);
        }
    }

    [DBus (name = "com.canonical.dbusmenu")]
    public class DBusMenuImpl : GLib.Object {
        [DBus (visible = false)]
        private unowned Application _app;
        [DBus (visible = false)]
        private unowned TrayIcon _tray;
        private uint _revision = 1;

        public DBusMenuImpl (Application app, TrayIcon tray) {
            _app = app;
            _tray = tray;
        }

        public uint version { get { return 3; } }
        public string status { owned get { return "normal"; } }
        public string text_direction { owned get { return "ltr"; } }
        public string[] icon_theme_path { owned get { return new string[] { _tray.icon_theme_path }; } }

        public signal void layout_updated (uint revision, int parent);
        public signal void items_properties_updated (Variant updated_props, Variant removed_props);
        public signal void item_activation_requested (int id, uint timestamp);

        [DBus (visible = false)]
        public void update_menu () {
            _revision++;
            layout_updated (_revision, 0);
        }

        private Variant build_item_node (int id, HashTable<string, Variant> props) {
            var b = new VariantBuilder (new VariantType ("(ia{sv}av)"));
            b.add ("i", id);
            b.open (new VariantType ("a{sv}"));
            var iter = HashTableIter<string, Variant> (props);
            string key;
            Variant val;
            while (iter.next (out key, out val)) {
                b.open (new VariantType ("{sv}"));
                b.add ("s", key);
                b.add ("v", val);
                b.close ();
            }
            b.close ();
            b.open (new VariantType ("av"));
            b.close ();
            return b.end ();
        }

        private HashTable<string, Variant>? get_item_props (int id) {
            var props = new HashTable<string, Variant> (str_hash, str_equal);
            switch (id) {
                case 0:
                    props.insert ("children-display", new Variant.string ("submenu"));
                    return props;
                case 1:
                    bool playing = _app.player.playing;
                    props.insert ("label", new Variant.string (playing ? _("Pause") : _("Play")));
                    props.insert ("icon-name", new Variant.string (playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic"));
                    props.insert ("enabled", new Variant.boolean (true));
                    props.insert ("visible", new Variant.boolean (true));
                    return props;
                case 2:
                    props.insert ("label", new Variant.string (_("Next")));
                    props.insert ("icon-name", new Variant.string ("media-skip-forward-symbolic"));
                    props.insert ("enabled", new Variant.boolean (true));
                    props.insert ("visible", new Variant.boolean (true));
                    return props;
                case 3:
                    props.insert ("label", new Variant.string (_("Previous")));
                    props.insert ("icon-name", new Variant.string ("media-skip-backward-symbolic"));
                    props.insert ("enabled", new Variant.boolean (true));
                    props.insert ("visible", new Variant.boolean (true));
                    return props;
                case 4:
                    props.insert ("type", new Variant.string ("separator"));
                    props.insert ("visible", new Variant.boolean (true));
                    return props;
                case 5:
                    props.insert ("label", new Variant.string (_("Open KIYORA")));
                    props.insert ("icon-name", new Variant.string ("window-restore-symbolic"));
                    props.insert ("enabled", new Variant.boolean (true));
                    props.insert ("visible", new Variant.boolean (true));
                    return props;
                case 6:
                    props.insert ("label", new Variant.string (_("Quit")));
                    props.insert ("icon-name", new Variant.string ("application-exit-symbolic"));
                    props.insert ("enabled", new Variant.boolean (true));
                    props.insert ("visible", new Variant.boolean (true));
                    return props;
                default:
                    return null;
            }
        }

        public void get_layout (int parent_id, int recursion_depth, string[] property_names, out uint revision, out Variant layout) throws GLib.Error {
            revision = _revision;
            var b = new VariantBuilder (new VariantType ("(ia{sv}av)"));
            b.add ("i", 0);
            b.open (new VariantType ("a{sv}"));
            b.open (new VariantType ("{sv}"));
            b.add ("s", "children-display");
            b.add ("v", new Variant.string ("submenu"));
            b.close ();
            b.close ();

            b.open (new VariantType ("av"));
            for (int i = 1; i <= 6; i++) {
                var props = get_item_props (i);
                if (props != null) {
                    b.add ("v", build_item_node (i, (!)props));
                }
            }
            b.close ();
            layout = b.end ();
        }

        public void get_group_properties (int[] ids, string[] property_names, out Variant properties) throws GLib.Error {
            var b = new VariantBuilder (new VariantType ("a(ia{sv})"));
            int[] all_ids = ids.length > 0 ? ids : new int[] { 0, 1, 2, 3, 4, 5, 6 };
            foreach (var id in all_ids) {
                var props = get_item_props (id);
                if (props != null) {
                    b.open (new VariantType ("(ia{sv})"));
                    b.add ("i", id);
                    b.open (new VariantType ("a{sv}"));
                    var iter = HashTableIter<string, Variant> ((!)props);
                    string key;
                    Variant val;
                    while (iter.next (out key, out val)) {
                        if (property_names.length == 0 || key in property_names) {
                            b.open (new VariantType ("{sv}"));
                            b.add ("s", key);
                            b.add ("v", val);
                            b.close ();
                        }
                    }
                    b.close ();
                    b.close ();
                }
            }
            properties = b.end ();
        }

        public new void get_property (int id, string name, out Variant value) throws GLib.Error {
            var props = get_item_props (id);
            if (props != null && ((!)props).contains (name)) {
                value = ((!)props).lookup (name);
            } else {
                value = new Variant.string ("");
            }
        }

        public void event (int id, string event_id, Variant data, uint timestamp) throws GLib.Error {
            if (event_id != "clicked")
                return;
            switch (id) {
                case 1:
                    _app.play_pause ();
                    break;
                case 2:
                    _app.play_next ();
                    break;
                case 3:
                    _app.play_previous ();
                    break;
                case 5:
                    _app.present_window ();
                    break;
                case 6:
                    _app.quit ();
                    break;
            }
        }

        public void event_group (Variant events, out int[] id_errors) throws GLib.Error {
            id_errors = new int[0];
            var iter = events.iterator ();
            Variant? item;
            while ((item = iter.next_value ()) != null) {
                var it = (!)item;
                int id = it.get_child_value (0).get_int32 ();
                string event_id = it.get_child_value (1).get_string ();
                Variant data = it.get_child_value (2);
                uint timestamp = it.get_child_value (3).get_uint32 ();
                event (id, event_id, data, timestamp);
            }
        }

        public void about_to_show (int id, out bool need_update) throws GLib.Error {
            need_update = false;
        }

        public void about_to_show_group (int[] ids, out int[] updates_needed, out int[] id_errors) throws GLib.Error {
            updates_needed = new int[0];
            id_errors = new int[0];
        }
    }

    public class TrayIcon : GLib.Object {
        private Application _app;
        private StatusNotifierItemImpl? _sni = null;
        private DBusMenuImpl? _menu = null;
        private uint _bus_id = 0;
        private bool _active = false;
        private uint _watcher_monitor_id = 0;
        private string _bus_name = "";
        private string _icon_theme_path = "";
        private Variant _icon_pixmap;

        public string icon_theme_path { get { return _icon_theme_path; } }
        public Variant icon_pixmap { get { return _icon_pixmap; } }

        public TrayIcon (Application app) {
            _app = app;
            _bus_name = "org.kde.StatusNotifierItem-%d-1".printf (Posix.getpid ());

            extract_icons ();
            _icon_pixmap = build_icon_pixmap ();

            _app.player.state_changed.connect (on_playback_state_changed);
            _app.music_changed.connect (on_music_changed);
            Adw.StyleManager.get_default ().notify["dark"].connect (on_theme_changed);

            _watcher_monitor_id = Bus.watch_name (BusType.SESSION, "org.kde.StatusNotifierWatcher",
                BusNameWatcherFlags.NONE,
                on_watcher_appeared,
                null
            );
        }

        public void set_active (bool active) {
            if (_active == active)
                return;
            _active = active;

            if (active) {
                register ();
            } else {
                unregister ();
            }
        }

        public Variant build_tool_tip () {
            var b = new VariantBuilder (new VariantType ("(sa(iiay)ss)"));
            b.add ("s", Config.APP_ID + "-symbolic");
            b.open (new VariantType ("a(iiay)"));
            b.close ();
            b.add ("s", _app.name);

            string desc;
            if (_app.current_music != null) {
                var music = (!) _app.current_music;
                string song_info = music.artist.length > 0 ? @"$(music.title) — $(music.artist)" : music.title;
                if (_app.player.playing) {
                    desc = @"▶ $song_info";
                } else {
                    desc = @"⏸ $song_info";
                }
            } else {
                desc = _("Not playing");
            }
            b.add ("s", desc);
            return b.end ();
        }

        private Variant build_icon_pixmap () {
            var builder = new VariantBuilder (new VariantType ("a(iiay)"));
            int[] sizes = { 16, 22, 24, 32, 48 };
            bool is_dark = Adw.StyleManager.get_default ().dark;

            uint8 fg_r = is_dark ? (uint8) 238 : (uint8) 45;
            uint8 fg_g = is_dark ? (uint8) 238 : (uint8) 45;
            uint8 fg_b = is_dark ? (uint8) 238 : (uint8) 45;

            uint8 bg_r = is_dark ? (uint8) 20 : (uint8) 240;
            uint8 bg_g = is_dark ? (uint8) 20 : (uint8) 240;
            uint8 bg_b = is_dark ? (uint8) 20 : (uint8) 240;

            foreach (var size in sizes) {
                try {
                    var pixbuf = new Gdk.Pixbuf.from_resource_at_scale (
                        "/io/github/Taskov1ch/KIYORA/icons/app-symbolic.svg",
                        size, size, true
                    );
                    int w = pixbuf.get_width ();
                    int h = pixbuf.get_height ();
                    int stride = pixbuf.get_rowstride ();
                    unowned uint8[] pixels = pixbuf.get_pixels_with_length ();

                    uint8[] data = new uint8[w * h * 4];

                    for (int y = 0; y < h; y++) {
                        for (int x = 0; x < w; x++) {
                            int src_idx = y * stride + x * 4;
                            uint8 alpha = pixels[src_idx + 3];
                            int dst_idx = (y * w + x) * 4;

                            if (alpha > 25) {
                                data[dst_idx + 0] = alpha;
                                data[dst_idx + 1] = fg_r;
                                data[dst_idx + 2] = fg_g;
                                data[dst_idx + 3] = fg_b;
                            } else {
                                bool has_neighbor = false;
                                for (int dy = -1; dy <= 1; dy++) {
                                    int ny = y + dy;
                                    if (ny < 0 || ny >= h) continue;
                                    for (int dx = -1; dx <= 1; dx++) {
                                        if (dx == 0 && dy == 0) continue;
                                        int nx = x + dx;
                                        if (nx < 0 || nx >= w) continue;
                                        if (pixels[ny * stride + nx * 4 + 3] > 60) {
                                            has_neighbor = true;
                                            break;
                                        }
                                    }
                                    if (has_neighbor) break;
                                }

                                if (has_neighbor) {
                                    data[dst_idx + 0] = 50;
                                    data[dst_idx + 1] = bg_r;
                                    data[dst_idx + 2] = bg_g;
                                    data[dst_idx + 3] = bg_b;
                                } else {
                                    data[dst_idx + 0] = 0;
                                    data[dst_idx + 1] = 0;
                                    data[dst_idx + 2] = 0;
                                    data[dst_idx + 3] = 0;
                                }
                            }
                        }
                    }

                    builder.open (new VariantType ("(iiay)"));
                    builder.add ("i", w);
                    builder.add ("i", h);
                    var byte_var = new Variant.from_bytes (new VariantType ("ay"), new Bytes (data), true);
                    builder.add_value (byte_var);
                    builder.close ();
                } catch (Error e) {
                    warning ("Failed to load icon pixmap at size %d: %s", size, e.message);
                }
            }
            return builder.end ();
        }

        private void extract_icons () {
            try {
                var base_dir = File.new_build_filename (Environment.get_user_cache_dir (), "kiyora", "icons");
                var scalable_dir = base_dir.get_child ("hicolor").get_child ("scalable").get_child ("apps");
                var symbolic_dir = base_dir.get_child ("hicolor").get_child ("symbolic").get_child ("apps");

                scalable_dir.make_directory_with_parents (null);
                symbolic_dir.make_directory_with_parents (null);

                _icon_theme_path = base_dir.get_path () ?? "";

                extract_resource_file ("/io/github/Taskov1ch/KIYORA/icons/app.svg",
                    scalable_dir.get_child (Config.APP_ID + ".svg"));
                extract_resource_file ("/io/github/Taskov1ch/KIYORA/icons/app-symbolic.svg",
                    scalable_dir.get_child (Config.APP_ID + "-symbolic.svg"));
                extract_resource_file ("/io/github/Taskov1ch/KIYORA/icons/app-symbolic.svg",
                    symbolic_dir.get_child (Config.APP_ID + "-symbolic.svg"));
            } catch (Error e) {
                warning ("Failed to extract tray icons to cache: %s", e.message);
            }
        }

        private void extract_resource_file (string res_path, File target) {
            try {
                if (target.query_exists ())
                    return;
                var bytes = GLib.resources_lookup_data (res_path, ResourceLookupFlags.NONE);
                var stream = target.replace (null, false, FileCreateFlags.NONE);
                stream.write_all (bytes.get_data (), null);
            } catch (Error e) {
            }
        }

        private void on_playback_state_changed (Gst.State state) {
            _menu?.update_menu ();
            _sni?.new_tool_tip ();
        }

        private void on_music_changed (Music? music) {
            _menu?.update_menu ();
            _sni?.new_tool_tip ();
        }

        private void on_theme_changed () {
            _icon_pixmap = build_icon_pixmap ();
            _sni?.new_icon ();
        }

        private void on_watcher_appeared (DBusConnection conn, string name, string name_owner) {
            if (_active && _bus_id != 0) {
                register_with_watcher ();
            }
        }

        private void register () {
            if (_bus_id != 0)
                return;

            _sni = new StatusNotifierItemImpl (_app, this);
            _menu = new DBusMenuImpl (_app, this);

            _bus_id = Bus.own_name (BusType.SESSION, _bus_name, BusNameOwnerFlags.NONE,
                on_bus_acquired,
                on_name_acquired,
                on_name_lost
            );
        }

        private void unregister () {
            if (_bus_id != 0) {
                Bus.unown_name (_bus_id);
                _bus_id = 0;
            }
            _sni = null;
            _menu = null;
        }

        private void on_bus_acquired (DBusConnection connection, string name) {
            try {
                if (_sni != null)
                    connection.register_object ("/StatusNotifierItem", _sni);
                if (_menu != null)
                    connection.register_object ("/MenuBar", _menu);
            } catch (Error e) {
                warning ("Register StatusNotifierItem failed: %s", e.message);
            }
        }

        private void on_name_acquired (DBusConnection connection, string name) {
            register_with_watcher ();
        }

        private void on_name_lost (DBusConnection connection, string name) {
        }

        private void register_with_watcher () {
            try {
                StatusNotifierWatcher watcher = Bus.get_proxy_sync (BusType.SESSION,
                    "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher");
                watcher.register_status_notifier_item (_bus_name);
            } catch (Error e) {
            }
        }

        public void shutdown () {
            set_active (false);
            if (_watcher_monitor_id != 0) {
                Bus.unwatch_name (_watcher_monitor_id);
                _watcher_monitor_id = 0;
            }
        }
    }
}
