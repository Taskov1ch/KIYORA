namespace G4 {

    private errordomain DiscordRpcError {
        INVALID_RESPONSE
    }

    private class DiscordRpcCommand : Object {
        public string payload;
        public bool has_activity;
        public bool quit;

        public DiscordRpcCommand (string payload, bool has_activity, bool quit = false) {
            this.payload = payload;
            this.has_activity = has_activity;
            this.quit = quit;
        }
    }

    public class DiscordRpc : Object {
        // Keep KIYORA's application so Discord displays "KIYORA", while mirroring
        // Harmonoid's Rich Presence fields and state transitions.
        private const string CLIENT_ID = "1358358227913543821";
        private const string DEFAULT_LARGE_IMAGE = "cover_default";
        private const string PAUSE_SMALL_IMAGE = "pause";
        private const string PLAY_SMALL_IMAGE = "play";
        private const int ACTIVITY_TYPE_LISTENING = 2;
        private const uint UPDATE_DELAY_MS = 250;
        private const uint RETRY_INTERVAL_SECONDS = 15;
        private const uint SOCKET_TIMEOUT_SECONDS = 2;
        private const uint32 MAX_FRAME_SIZE = 1024 * 1024;

        private unowned Application _app;
        private AsyncQueue<DiscordRpcCommand> _commands = new AsyncQueue<DiscordRpcCommand> ();
        private string _current_uri = "";
        private string _large_image = DEFAULT_LARGE_IMAGE;
        private Gst.ClockTime _duration = Gst.CLOCK_TIME_NONE;
        private Gst.ClockTime _flag_position = Gst.CLOCK_TIME_NONE;
        private Thread<bool>? _worker = null;
        private ulong _cover_changed_id = 0;
        private Cancellable? _upload_cancellable = null;
        private Settings _settings;
        private ulong _duration_changed_id = 0;
        private ulong _music_changed_id = 0;
        private ulong _position_updated_id = 0;
        private ulong _state_changed_id = 0;
        private uint _retry_id = 0;
        private uint _update_id = 0;
        private bool _stopped = false;

        public DiscordRpc (Application app) {
            _settings = app.settings;
            _app = app;
            _worker = new Thread<bool> ("discord-rpc", worker_loop);

            _music_changed_id = app.music_changed.connect ((music) => {
                var uri = music?.uri ?? "";
                if (_current_uri != uri) {
                    _current_uri = uri;
                    _duration = Gst.CLOCK_TIME_NONE;
                    _flag_position = Gst.CLOCK_TIME_NONE;
                    _large_image = get_cover_image (music?.cover_uri);
                    if (music != null) {
                        try_upload_cover (music, null, ((!)music).cover_uri);
                    }
                }
                schedule_update ();
            });
            _cover_changed_id = app.music_cover_parsed.connect ((music, pixbuf, uri) => {
                if (music.uri != _current_uri)
                    return;
                var large_image = get_cover_image (uri);
                if (large_image != DEFAULT_LARGE_IMAGE) {
                    if (_large_image != large_image) {
                        _large_image = large_image;
                        schedule_update ();
                    }
                } else if (_large_image == DEFAULT_LARGE_IMAGE) {
                    try_upload_cover (music, pixbuf, uri);
                }
            });
            _duration_changed_id = app.player.duration_changed.connect ((duration) => {
                _duration = duration;
                schedule_update ();
            });
            _position_updated_id = app.player.position_updated.connect ((position) => {
                if (position_requires_update (position))
                    schedule_update ();
            });
            _state_changed_id = app.player.state_changed.connect (() => schedule_update ());

            _retry_id = Timeout.add_seconds (RETRY_INTERVAL_SECONDS, () => {
                if (_stopped)
                    return Source.REMOVE;
                enqueue_current_activity ();
                return Source.CONTINUE;
            });

            schedule_update ();
        }

        public void shutdown () {
            if (_stopped)
                return;
            _stopped = true;

            if (_update_id != 0) {
                Source.remove (_update_id);
                _update_id = 0;
            }
            if (_retry_id != 0) {
                Source.remove (_retry_id);
                _retry_id = 0;
            }

            disconnect_signals ();
            _commands.push (new DiscordRpcCommand (build_command (null, false), false, true));
            _worker?.join ();
            _worker = null;
        }

                private void try_upload_cover (Music? music, Gdk.Pixbuf? pixbuf, string? uri) {
            if (music == null) return;
            if (_upload_cancellable != null) {
                ((!)_upload_cancellable).cancel ();
                _upload_cancellable = null;
            }

            var provider = _settings.get_uint ("discord-cover-provider");
            if (provider == 0) return;

            if (uri != null && (((!)uri).has_prefix ("http://") || ((!)uri).has_prefix ("https://")))
                return;

            Gdk.Pixbuf? cover = pixbuf;
            if (cover == null && uri != null) {
                try {
                    var file = File.new_for_uri ((!)uri);
                    if (file.query_exists ()) {
                        var path = file.get_path ();
                        if (path != null)
                            cover = new Gdk.Pixbuf.from_file ((!)path);
                    }
                } catch (Error e) {
                    return;
                }
            }

            if (cover == null) return;

            _upload_cancellable = new Cancellable ();
            upload_cover_async.begin ((!)music, (!)cover, provider, _settings.get_string ("discord-imgbb-api-key"), _upload_cancellable, (obj, res) => {
                try {
                    var url = upload_cover_async.end (res);
                    if (url != null && ((!)url).length > 0 && ((!)music).uri == _current_uri) {
                        _large_image = (!)url;
                        schedule_update ();
                    }
                } catch (Error e) {
                    if (!(e is IOError.CANCELLED))
                        warning ("Cover upload failed: %s", e.message);
                }
            });
        }

        private async string? upload_cover_async (Music music, Gdk.Pixbuf original, uint provider, string api_key, Cancellable? cancellable) throws Error {
            int width = original.get_width ();
            int height = original.get_height ();
            int size = int.min (width, height);
            
            Gdk.Pixbuf processed = original;
            if (width != height) {
                processed = new Gdk.Pixbuf.subpixbuf (original, (width - size) / 2, (height - size) / 2, size, size);
            }
            if (size > 512) {
                processed = (!)processed.scale_simple (512, 512, Gdk.InterpType.BILINEAR);
            }

            uint8[] buffer;
            processed.save_to_buffer (out buffer, "jpeg", "quality", "90");

            var session = new Soup.Session ();
            var multipart = new Soup.Multipart (Soup.FORM_MIME_TYPE_MULTIPART);

            var uri_str = provider == 1 ? "https://catbox.moe/user/api.php" : "https://api.imgbb.com/1/upload";

            var title = get_title (music);
            var artist = get_artist (music);
            var filename = GLib.Base64.encode ((title + " - " + artist).data).replace ("/", "_").replace ("+", "-").replace ("=", "") + ".jpg";

            if (provider == 1) {
                multipart.append_form_string ("reqtype", "fileupload");
                multipart.append_form_file ("fileToUpload", filename, "image/jpeg", new Bytes (buffer));
            } else if (provider == 2) {
                multipart.append_form_string ("key", api_key);
                multipart.append_form_file ("image", filename, "image/jpeg", new Bytes (buffer));
            }

            var msg = new Soup.Message.from_multipart (uri_str, multipart);
            var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, cancellable);
            if (msg.status_code != 200) {
                throw new IOError.FAILED ("HTTP Error: %u", msg.status_code);
            }

            string response = (string) bytes.get_data ();
            
            string? url = null;
            if (provider == 1) {
                url = response.strip ();
            } else if (provider == 2) {
                var parser = new Json.Parser ();
                parser.load_from_data (response);
                unowned Json.Object? root = parser.get_root ()?.get_object ();
                if (root != null) {
                    unowned Json.Object? data = ((!)root).get_object_member ("data");
                    if (data != null) {
                        url = ((!)data).get_string_member ("url");
                    }
                }
                if (url == null) {
                    throw new IOError.FAILED ("Invalid ImgBB response");
                }
            }

            if (url != null && ((!)url).length > 0) {
                var check_msg = new Soup.Message ("HEAD", (!)url);
                yield session.send_and_read_async (check_msg, Priority.DEFAULT, cancellable);
                if (check_msg.status_code == 404) {
                    return "https://i.ibb.co/LXT2kyzG/b9267e02-8cd6-4560-bd23-750d6645ee6a.png";
                }
                return url;
            }
            return null;
        }

        private void disconnect_signals () {
            if (_music_changed_id != 0) {
                SignalHandler.disconnect (_app, _music_changed_id);
                _music_changed_id = 0;
            }
            if (_cover_changed_id != 0) {
                SignalHandler.disconnect (_app, _cover_changed_id);
                _cover_changed_id = 0;
            }
            if (_duration_changed_id != 0) {
                SignalHandler.disconnect (_app.player, _duration_changed_id);
                _duration_changed_id = 0;
            }
            if (_position_updated_id != 0) {
                SignalHandler.disconnect (_app.player, _position_updated_id);
                _position_updated_id = 0;
            }
            if (_state_changed_id != 0) {
                SignalHandler.disconnect (_app.player, _state_changed_id);
                _state_changed_id = 0;
            }
        }

        private bool position_requires_update (Gst.ClockTime position) {
            if (position == Gst.CLOCK_TIME_NONE)
                return false;
            if (_flag_position == Gst.CLOCK_TIME_NONE)
                return true;
            var difference = position > _flag_position
                ? position - _flag_position
                : _flag_position - position;
            return difference > 10 * Gst.SECOND;
        }

        private void schedule_update () {
            if (_stopped)
                return;
            if (_update_id != 0)
                Source.remove (_update_id);
            _update_id = Timeout.add (UPDATE_DELAY_MS, () => {
                _update_id = 0;
                enqueue_current_activity ();
                return Source.REMOVE;
            });
        }

        private void enqueue_current_activity () {
            if (_stopped)
                return;

            unowned Music? music = _app.current_music;
            var playing = music != null && _app.player.state == Gst.State.PLAYING;
            _flag_position = _app.player.position;
            _commands.push (new DiscordRpcCommand (
                build_command (music, playing), music != null
            ));
        }

        private string build_command (Music? music, bool playing) {
            var builder = new Json.Builder ();
            builder.begin_object ();
            builder.set_member_name ("cmd");
            builder.add_string_value ("SET_ACTIVITY");
            builder.set_member_name ("args");
            builder.begin_object ();
            builder.set_member_name ("pid");
            builder.add_int_value ((int64) Posix.getpid ());
            builder.set_member_name ("activity");

            if (music == null) {
                builder.add_null_value ();
            } else {
                var title = get_title ((!)music);
                var artist = get_artist ((!)music);
                var description = get_description ((!)music);

                builder.begin_object ();
                builder.set_member_name ("type");
                builder.add_int_value (ACTIVITY_TYPE_LISTENING);
                if (title.strip ().length > 0) {
                    builder.set_member_name ("details");
                    builder.add_string_value (truncate_rpc_text (title));
                }
                if (artist.length > 0) {
                    builder.set_member_name ("state");
                    builder.add_string_value (truncate_rpc_text (artist));
                }

                if (playing) {
                    var position = _app.player.position;
                    if (position != Gst.CLOCK_TIME_NONE) {
                        var now = get_real_time () / 1000000;
                        var position_seconds = (int64) (position / Gst.SECOND);
                        var start = int64.max (0, now - position_seconds);

                        builder.set_member_name ("timestamps");
                        builder.begin_object ();
                        builder.set_member_name ("start");
                        builder.add_int_value (start);
                        if (_duration != Gst.CLOCK_TIME_NONE && _duration > 0) {
                            builder.set_member_name ("end");
                            builder.add_int_value (start + (int64) (_duration / Gst.SECOND));
                        }
                        builder.end_object ();
                    }
                }

                builder.set_member_name ("assets");
                builder.begin_object ();
                builder.set_member_name ("large_image");
                builder.add_string_value (_large_image);
                builder.set_member_name ("small_image");
                builder.add_string_value (playing ? PLAY_SMALL_IMAGE : PAUSE_SMALL_IMAGE);
                if (description.length > 0) {
                    builder.set_member_name ("large_text");
                    builder.add_string_value (truncate_rpc_text (description));
                }
                builder.set_member_name ("small_text");
                builder.add_string_value (playing ? _("Playing") : _("Paused"));
                builder.end_object ();

                builder.set_member_name ("buttons");
                builder.begin_array ();
                builder.begin_object ();
                builder.set_member_name ("label");
                builder.add_string_value (_("Find"));
                builder.set_member_name ("url");
                builder.add_string_value (build_search_url (title, artist));
                builder.end_object ();
                builder.end_array ();
                builder.end_object ();
            }

            builder.end_object ();
            builder.set_member_name ("nonce");
            builder.add_string_value (Uuid.string_random ());
            builder.end_object ();

            var generator = new Json.Generator ();
            generator.set_root ((!)builder.get_root ());
            return generator.to_data (null);
        }

        private static string get_title (Music music) {
            var title = music.title.strip ();
            if (title.length > 0)
                return title;
            return File.new_for_uri (music.uri).get_basename () ?? "KIYORA";
        }

        private static string get_artist (Music music) {
            var artist = music.artist.strip ();
            return artist == UNKNOWN_ARTIST ? "" : artist;
        }

        private static string get_description (Music music) {
            var album = music.album.strip ();
            if (album == UNKNOWN_ALBUM)
                album = "";
            var year = music.date / 400;
            if (album.length > 0 && year > 0)
                return @"$album • $year";
            if (album.length > 0)
                return album;
            return year > 0 ? year.to_string () : "";
        }

        private static string get_cover_image (string? uri) {
            if (uri != null && (((!)uri).has_prefix ("https://") || ((!)uri).has_prefix ("http://")))
                return (!)uri;
            return DEFAULT_LARGE_IMAGE;
        }

        private static string build_search_url (string title, string artist) {
            var query = artist.length > 0 ? @"$title $artist" : title;
            return "https://www.google.com/search?q=" + Uri.escape_string (query, null, false);
        }

        private static string truncate_rpc_text (string text) {
            const int MAX_CHARS = 128;
            if (text.char_count () <= MAX_CHARS)
                return text;
            return text.substring (0, text.index_of_nth_char (MAX_CHARS - 3)) + "...";
        }

        private bool worker_loop () {
            SocketConnection? connection = null;
            var activity_set = false;

            while (true) {
                var command = _commands.pop ();
                DiscordRpcCommand? newer = null;
                while ((newer = _commands.try_pop ()) != null)
                    command = (!)newer;

                if (command.quit) {
                    if (connection != null && activity_set) {
                        try {
                            send_frame ((!)connection, 1, command.payload);
                            receive_frame ((!)connection);
                        } catch (Error e) {
                            debug ("Unable to clear Discord activity during shutdown: %s", e.message);
                        }
                    }
                    close_connection (ref connection);
                    return true;
                }

                if (!command.has_activity && (!activity_set || connection == null))
                    continue;

                if (connection == null && !connect_discord (out connection))
                    continue;

                try {
                    send_frame ((!)connection, 1, command.payload);
                    receive_frame ((!)connection);
                    activity_set = command.has_activity;
                    debug (command.has_activity
                        ? "Discord activity updated"
                        : "Discord activity cleared");
                        
                } catch (Error e) {
                    warning ("Discord RPC update failed: %s", e.message);
                    activity_set = false;
                    close_connection (ref connection);
                }
            }
        }

        private static bool connect_discord (out SocketConnection? connection) {
            connection = null;
            Error? last_error = null;
            var found_socket = false;
            string[] environment_keys = { "XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP" };
            string[] subpaths = {
                "",
                "app/com.discordapp.Discord",
                "app/dev.vencord.Vesktop",
                "snap.discord-canary",
                "snap.discord"
            };

            foreach (var key in environment_keys) {
                var base_path = Environment.get_variable (key);
                if (base_path == null || ((!)base_path).length == 0)
                    continue;

                for (var index = 0; index < 10; index++) {
                    foreach (var subpath in subpaths) {
                        var path = subpath.length > 0
                            ? Path.build_filename ((!)base_path, subpath, @"discord-ipc-$index")
                            : Path.build_filename ((!)base_path, @"discord-ipc-$index");
                        if (!FileUtils.test (path, FileTest.EXISTS))
                            continue;
                        found_socket = true;

                        SocketConnection? candidate = null;
                        try {
                            var client = new SocketClient ();
                            client.timeout = SOCKET_TIMEOUT_SECONDS;
                            candidate = client.connect (new UnixSocketAddress (path));
                            ((!)candidate).socket.timeout = SOCKET_TIMEOUT_SECONDS;
                            send_frame ((!)candidate, 0,
                                @"{\"v\":1,\"client_id\":\"$CLIENT_ID\"}");
                            receive_frame ((!)candidate);
                            connection = candidate;
                            debug ("Connected to Discord RPC at %s", path);
                            return true;
                        } catch (Error e) {
                            last_error = e;
                            close_connection (ref candidate);
                        }
                    }
                }
            }

            if (found_socket && last_error != null)
                warning ("Unable to connect to Discord RPC: %s", ((!)last_error).message);
            else
                debug ("Discord RPC socket was not found");
            return false;
        }

        private static void send_frame (SocketConnection connection, uint32 opcode,
                                        string payload) throws Error {
            uint8[] header = new uint8[8];
            var size = (uint32) payload.length;
            write_uint32_le (header, 0, opcode);
            write_uint32_le (header, 4, size);

            size_t written = 0;
            if (!connection.output_stream.write_all (header, out written) || written != header.length)
                throw new IOError.FAILED ("Could not write Discord RPC frame header");

            unowned uint8[] data = (uint8[]) payload;
            if (!connection.output_stream.write_all (data[0:payload.length], out written)
                    || written != payload.length)
                throw new IOError.FAILED ("Could not write Discord RPC frame payload");
            connection.output_stream.flush ();
        }

        private static void receive_frame (SocketConnection connection) throws Error {
            uint8[] header = new uint8[8];
            size_t bytes_read = 0;
            if (!connection.input_stream.read_all (header, out bytes_read) || bytes_read != header.length)
                throw new IOError.FAILED ("Could not read Discord RPC frame header");

            var opcode = read_uint32_le (header, 0);
            var size = read_uint32_le (header, 4);
            if (size > MAX_FRAME_SIZE)
                throw new DiscordRpcError.INVALID_RESPONSE ("Discord RPC frame is too large");

            if (size > 0) {
                // Keep one trailing NUL so the byte buffer can be parsed as a Vala string.
                uint8[] payload = new uint8[size + 1];
                if (!connection.input_stream.read_all (payload[0:size], out bytes_read) || bytes_read != size)
                    throw new IOError.FAILED ("Could not read Discord RPC frame payload");

                var parser = new Json.Parser ();
                parser.load_from_data ((string) payload, size);
                unowned Json.Object? response = parser.get_root ()?.get_object ();
                if (response?.get_string_member_with_default ("evt", "") == "ERROR") {
                    unowned Json.Object? data = response?.get_object_member ("data");
                    var message = data?.get_string_member_with_default (
                        "message", "Discord rejected the RPC request"
                    ) ?? "Discord rejected the RPC request";
                    throw new DiscordRpcError.INVALID_RESPONSE (message);
                }
            }
            if (opcode == 2)
                throw new DiscordRpcError.INVALID_RESPONSE ("Discord closed the RPC connection");
        }

        private static void close_connection (ref SocketConnection? connection) {
            if (connection == null)
                return;
            try {
                send_frame ((!)connection, 2, "{}");
            } catch (Error e) {
            }
            try {
                ((!)connection).close ();
            } catch (Error e) {
            }
            connection = null;
        }

        private static void write_uint32_le (uint8[] data, int offset, uint32 value) {
            data[offset] = (uint8) (value & 0xff);
            data[offset + 1] = (uint8) ((value >> 8) & 0xff);
            data[offset + 2] = (uint8) ((value >> 16) & 0xff);
            data[offset + 3] = (uint8) ((value >> 24) & 0xff);
        }

        private static uint32 read_uint32_le (uint8[] data, int offset) {
            return (uint32) data[offset]
                | ((uint32) data[offset + 1] << 8)
                | ((uint32) data[offset + 2] << 16)
                | ((uint32) data[offset + 3] << 24);
        }
    }
}
