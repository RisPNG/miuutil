#include <adwaita.h>
#include <nautilus-extension.h>

typedef struct {
    GObject parent_instance;
} MiuNautilusTabs;

typedef struct {
    GObjectClass parent_class;
} MiuNautilusTabsClass;

typedef struct {
    GApplication *application;
    GDBusConnection *connection;
    GDBusMessage *message;
} FileManagerRequest;

typedef struct {
    char *uri;
    GHashTable *selection;
    char *startup_id;
} ExternalLocation;

typedef struct {
    GQueue locations;
    guint source;
} ExternalLocations;

static void miu_nautilus_tabs_column_provider_init (NautilusColumnProviderInterface *interface);

G_DEFINE_DYNAMIC_TYPE_EXTENDED (MiuNautilusTabs, miu_nautilus_tabs, G_TYPE_OBJECT, 0,
    G_IMPLEMENT_INTERFACE_DYNAMIC (NAUTILUS_TYPE_COLUMN_PROVIDER,
                                   miu_nautilus_tabs_column_provider_init))

static GType extension_types[1];

static gboolean
external_tabs_enabled (void)
{
    g_autoptr (GKeyFile) settings = g_key_file_new ();
    g_autofree char *user_path = g_build_filename (g_get_user_config_dir (), "miu", "nautilus-tabs.conf", NULL);

    if (g_key_file_load_from_file (settings, user_path, G_KEY_FILE_NONE, NULL)) {
        return g_key_file_get_boolean (settings, "Nautilus", "external-tabs", NULL);
    }

    const char * const *directories = g_get_system_config_dirs ();
    for (guint index = 0; directories[index] != NULL; index++) {
        g_autofree char *path = g_build_filename (directories[index], "miu", "nautilus-tabs.conf", NULL);
        if (g_key_file_load_from_file (settings, path, G_KEY_FILE_NONE, NULL)) {
            return g_key_file_get_boolean (settings, "Nautilus", "external-tabs", NULL);
        }
    }

    return FALSE;
}

static void
select_requested_items (GObject *slot, GParamSpec *property G_GNUC_UNUSED,
                        gpointer data G_GNUC_UNUSED)
{
    gboolean loading;
    g_object_get (slot, "loading", &loading, NULL);
    if (loading) {
        return;
    }

    GHashTable *uris = g_object_get_data (slot, "miu-tab-selection");
    g_autoptr (GPtrArray) widgets = g_ptr_array_new ();
    g_ptr_array_add (widgets, slot);
    while (widgets->len > 0) {
        GtkWidget *widget = g_ptr_array_steal_index (widgets, widgets->len - 1);
        GtkSelectionModel *model = NULL;
        if (GTK_IS_GRID_VIEW (widget)) {
            model = gtk_grid_view_get_model (GTK_GRID_VIEW (widget));
        } else if (GTK_IS_COLUMN_VIEW (widget)) {
            model = gtk_column_view_get_model (GTK_COLUMN_VIEW (widget));
        } else if (GTK_IS_LIST_VIEW (widget)) {
            model = gtk_list_view_get_model (GTK_LIST_VIEW (widget));
        }

        if (model != NULL) {
            gtk_selection_model_unselect_all (model);
            for (guint index = 0; index < g_list_model_get_n_items (G_LIST_MODEL (model)); index++) {
                g_autoptr (GObject) item = g_list_model_get_item (G_LIST_MODEL (model), index);
                g_autoptr (GObject) view_item = GTK_IS_TREE_LIST_ROW (item) ?
                    gtk_tree_list_row_get_item (GTK_TREE_LIST_ROW (item)) : g_object_ref (item);
                g_autoptr (NautilusFileInfo) file = NULL;
                g_object_get (view_item, "file", &file, NULL);
                g_autofree char *uri = nautilus_file_info_get_uri (file);
                if (g_hash_table_contains (uris, uri)) {
                    gtk_selection_model_select_item (model, index, FALSE);
                    if (GTK_IS_GRID_VIEW (widget)) {
                        gtk_grid_view_scroll_to (GTK_GRID_VIEW (widget), index, GTK_LIST_SCROLL_FOCUS, NULL);
                    } else if (GTK_IS_COLUMN_VIEW (widget)) {
                        gtk_column_view_scroll_to (GTK_COLUMN_VIEW (widget), index, NULL, GTK_LIST_SCROLL_FOCUS, NULL);
                    } else {
                        gtk_list_view_scroll_to (GTK_LIST_VIEW (widget), index, GTK_LIST_SCROLL_FOCUS, NULL);
                    }
                }
            }
            break;
        }

        for (GtkWidget *child = gtk_widget_get_first_child (widget); child != NULL;
             child = gtk_widget_get_next_sibling (child)) {
            g_ptr_array_add (widgets, child);
        }
    }

    g_signal_handlers_disconnect_by_func (slot, select_requested_items, NULL);
    g_object_set_data (slot, "miu-tab-selection", NULL);
}

static void
browser_location_changed (GObject *slot, GParamSpec *property G_GNUC_UNUSED,
                          gpointer data G_GNUC_UNUSED)
{
    g_autoptr (GFile) location = NULL;
    g_object_get (slot, "location", &location, NULL);
    if (location != NULL) {
        g_object_set_data (slot, "miu-location-established", GINT_TO_POINTER (1));
        g_signal_handlers_disconnect_by_func (slot, browser_location_changed, NULL);
    }
}

static void
browser_tabs_changed (GListModel *pages, guint position, guint removed G_GNUC_UNUSED,
                      guint added, gpointer data G_GNUC_UNUSED)
{
    for (guint index = position; index < position + added; index++) {
        g_autoptr (AdwTabPage) page = g_list_model_get_item (pages, index);
        GtkWidget *slot = adw_tab_page_get_child (page);
        if (g_object_get_data (G_OBJECT (slot), "miu-location-observed") == NULL) {
            g_object_set_data (G_OBJECT (slot), "miu-location-observed", GINT_TO_POINTER (1));
            g_signal_connect (slot, "notify::location", G_CALLBACK (browser_location_changed), NULL);
        }
    }
}

static void
browser_window_added (GtkApplication *application G_GNUC_UNUSED, GtkWindow *window,
                      gpointer data G_GNUC_UNUSED)
{
    if (g_object_class_find_property (G_OBJECT_GET_CLASS (window), "active-slot") == NULL) {
        return;
    }
    g_autoptr (GPtrArray) widgets = g_ptr_array_new ();
    g_ptr_array_add (widgets, window);
    while (widgets->len > 0) {
        GtkWidget *widget = g_ptr_array_steal_index (widgets, widgets->len - 1);
        if (ADW_IS_TAB_VIEW (widget)) {
            g_autoptr (GtkSelectionModel) pages = adw_tab_view_get_pages (ADW_TAB_VIEW (widget));
            g_object_set_data_full (G_OBJECT (window), "miu-tab-pages", g_object_ref (pages), g_object_unref);
            g_signal_connect (pages, "items-changed", G_CALLBACK (browser_tabs_changed), NULL);
            browser_tabs_changed (G_LIST_MODEL (pages), 0, 0, g_list_model_get_n_items (G_LIST_MODEL (pages)), NULL);
            break;
        }
        for (GtkWidget *child = gtk_widget_get_first_child (widget); child != NULL;
             child = gtk_widget_get_next_sibling (child)) {
            g_ptr_array_add (widgets, child);
        }
    }
}

static gboolean
open_next_external_location (gpointer data)
{
    GApplication *application = data;
    ExternalLocations *pending = g_object_get_data (G_OBJECT (application), "miu-pending-locations");
    GtkWindow *window = gtk_application_get_active_window (GTK_APPLICATION (application));
    if (window == NULL || g_object_class_find_property (G_OBJECT_GET_CLASS (window), "active-slot") == NULL) {
        window = NULL;
        for (GList *opened = gtk_application_get_windows (GTK_APPLICATION (application)); opened != NULL;
             opened = opened->next) {
            if (g_object_class_find_property (G_OBJECT_GET_CLASS (opened->data), "active-slot") != NULL) {
                window = opened->data;
                break;
            }
        }
    }
    if (window != NULL) {
        g_autoptr (GtkWidget) current = NULL;
        g_autoptr (GFile) current_location = NULL;
        g_object_get (window, "active-slot", &current, NULL);
        g_object_get (current, "location", &current_location, NULL);
        if (current_location == NULL ||
            g_object_get_data (G_OBJECT (current), "miu-location-established") == NULL) {
            return G_SOURCE_CONTINUE;
        }
        g_action_group_activate_action (G_ACTION_GROUP (window), "new-tab", NULL);
    } else {
        g_action_group_activate_action (G_ACTION_GROUP (application), "new-window", NULL);
        window = gtk_application_get_windows (GTK_APPLICATION (application))->data;
    }

    ExternalLocation *location = g_queue_pop_head (&pending->locations);
    g_autoptr (GtkWidget) slot = NULL;
    g_object_get (window, "active-slot", &slot, NULL);
    g_autoptr (GPtrArray) widgets = g_ptr_array_new ();
    g_ptr_array_add (widgets, window);
    while (widgets->len > 0) {
        GtkWidget *widget = g_ptr_array_steal_index (widgets, widgets->len - 1);
        if (ADW_IS_TAB_VIEW (widget)) {
            AdwTabView *tabs = ADW_TAB_VIEW (widget);
            AdwTabPage *page = adw_tab_view_get_page (tabs, slot);
            adw_tab_view_reorder_page (tabs, page, adw_tab_view_get_n_pages (tabs) - 1);
            break;
        }
        for (GtkWidget *child = gtk_widget_get_first_child (widget); child != NULL;
             child = gtk_widget_get_next_sibling (child)) {
            g_ptr_array_add (widgets, child);
        }
    }

    if (g_hash_table_size (location->selection) > 0) {
        g_object_set_data_full (G_OBJECT (slot), "miu-tab-selection", g_hash_table_ref (location->selection),
                                (GDestroyNotify) g_hash_table_unref);
        g_signal_connect (slot, "notify::loading", G_CALLBACK (select_requested_items), NULL);
    }
    gtk_widget_activate_action (slot, "slot.open-location", "s", location->uri);
    if (location->startup_id != NULL && location->startup_id[0] != '\0') {
        gtk_window_set_startup_id (window, location->startup_id);
    }
    gtk_window_present (window);
    g_hash_table_unref (location->selection);
    g_free (location->uri);
    g_free (location->startup_id);
    g_free (location);

    if (g_queue_is_empty (&pending->locations)) {
        pending->source = 0;
        g_application_release (application);
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

static void
open_external_locations (GApplication *application, GFile **files, guint count,
                         gboolean select, const char *startup_id)
{
    if (count == 0) {
        return;
    }
    ExternalLocations *pending = g_object_get_data (G_OBJECT (application), "miu-pending-locations");
    gboolean first = g_queue_is_empty (&pending->locations);
    g_autoptr (GHashTable) requests = g_hash_table_new (g_str_hash, g_str_equal);
    for (guint index = 0; index < count; index++) {
        g_autoptr (GFile) parent = select ? g_file_get_parent (files[index]) : NULL;
        g_autofree char *uri = g_file_get_uri (parent != NULL ? parent : files[index]);
        ExternalLocation *location = g_hash_table_lookup (requests, uri);
        if (location == NULL) {
            location = g_new (ExternalLocation, 1);
            location->uri = g_strdup (uri);
            location->selection = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
            location->startup_id = g_strdup (startup_id);
            g_hash_table_insert (requests, location->uri, location);
            g_queue_push_tail (&pending->locations, location);
        }
        if (select && parent != NULL) {
            g_hash_table_add (location->selection, g_file_get_uri (files[index]));
        }
    }
    if (first) {
        g_application_hold (application);
        if (open_next_external_location (application) == G_SOURCE_CONTINUE) {
            pending->source = g_timeout_add_full (G_PRIORITY_DEFAULT, 20, open_next_external_location,
                                                  g_object_ref (application), g_object_unref);
        }
    }
}

static void
application_open (GApplication *application, GFile **files, gint count,
                  const char *hint G_GNUC_UNUSED, gpointer data G_GNUC_UNUSED)
{
    open_external_locations (application, files, count, FALSE, NULL);
    g_signal_stop_emission_by_name (application, "open");
}

static void
application_activate (GApplication *application, gpointer data G_GNUC_UNUSED)
{
    g_autoptr (GFile) home = g_file_new_for_path (g_get_home_dir ());
    open_external_locations (application, &home, 1, FALSE, NULL);
    g_signal_stop_emission_by_name (application, "activate");
}

static gint
application_command_line (GApplication *application, GApplicationCommandLine *command_line,
                          gpointer data G_GNUC_UNUSED)
{
    GVariantDict *options = g_application_command_line_get_options_dict (command_line);
    if (g_variant_dict_contains (options, "quit") || g_variant_dict_contains (options, "version")) {
        return G_APPLICATION_GET_CLASS (application)->command_line (application, command_line);
    }

    g_auto (GStrv) remaining = NULL;
    g_variant_dict_lookup (options, G_OPTION_REMAINING, "^as", &remaining);
    g_autoptr (GPtrArray) files = g_ptr_array_new_with_free_func (g_object_unref);
    if (remaining != NULL) {
        for (guint index = 0; remaining[index] != NULL; index++) {
            g_ptr_array_add (files, g_application_command_line_create_file_for_arg (command_line, remaining[index]));
        }
    } else if (g_variant_dict_contains (options, "select")) {
        return G_APPLICATION_GET_CLASS (application)->command_line (application, command_line);
    } else {
        g_ptr_array_add (files, g_file_new_for_path (g_get_home_dir ()));
    }
    open_external_locations (application, (GFile **) files->pdata, files->len,
                             g_variant_dict_contains (options, "select"), NULL);
    g_signal_stop_emission_by_name (application, "command-line");
    return 0;
}

static gboolean
file_manager_request (gpointer data)
{
    FileManagerRequest *request = data;
    g_auto (GStrv) uris = NULL;
    const char *startup_id;
    g_variant_get (g_dbus_message_get_body (request->message), "(^as&s)", &uris, &startup_id);
    g_autoptr (GPtrArray) files = g_ptr_array_new_with_free_func (g_object_unref);
    for (guint index = 0; uris[index] != NULL; index++) {
        g_ptr_array_add (files, g_file_new_for_uri (uris[index]));
    }
    open_external_locations (request->application, (GFile **) files->pdata, files->len,
                             g_str_equal (g_dbus_message_get_member (request->message), "ShowItems"), startup_id);
    g_autoptr (GDBusMessage) reply = g_dbus_message_new_method_reply (request->message);
    g_dbus_connection_send_message (request->connection, reply, G_DBUS_SEND_MESSAGE_FLAGS_NONE, NULL, NULL);
    return G_SOURCE_REMOVE;
}

static void
file_manager_request_free (gpointer data)
{
    FileManagerRequest *request = data;
    g_object_unref (request->application);
    g_object_unref (request->connection);
    g_object_unref (request->message);
    g_free (request);
}

static GDBusMessage *
file_manager_filter (GDBusConnection *connection, GDBusMessage *message,
                     gboolean incoming, gpointer data)
{
    const char *method = g_dbus_message_get_member (message);
    GVariant *body = g_dbus_message_get_body (message);
    if (incoming && g_dbus_message_get_message_type (message) == G_DBUS_MESSAGE_TYPE_METHOD_CALL &&
        g_strcmp0 (g_dbus_message_get_path (message), "/org/freedesktop/FileManager1") == 0 &&
        g_strcmp0 (g_dbus_message_get_interface (message), "org.freedesktop.FileManager1") == 0 &&
        (g_strcmp0 (method, "ShowItems") == 0 || g_strcmp0 (method, "ShowFolders") == 0) &&
        body != NULL && g_variant_is_of_type (body, G_VARIANT_TYPE ("(ass)"))) {
        FileManagerRequest *request = g_new (FileManagerRequest, 1);
        request->application = g_object_ref (data);
        request->connection = g_object_ref (connection);
        request->message = message;
        g_idle_add_full (G_PRIORITY_DEFAULT, file_manager_request, request, file_manager_request_free);
        return NULL;
    }
    return message;
}

static GList *
get_columns (NautilusColumnProvider *provider G_GNUC_UNUSED)
{
    return NULL;
}

static void
miu_nautilus_tabs_column_provider_init (NautilusColumnProviderInterface *interface)
{
    interface->get_columns = get_columns;
}

static void
miu_nautilus_tabs_init (MiuNautilusTabs *self G_GNUC_UNUSED)
{
    GApplication *application = g_application_get_default ();
    if (!external_tabs_enabled () || g_object_get_data (G_OBJECT (application), "miu-external-tabs") != NULL) {
        return;
    }
    g_object_set_data (G_OBJECT (application), "miu-external-tabs", GINT_TO_POINTER (1));
    ExternalLocations *pending = g_new0 (ExternalLocations, 1);
    g_object_set_data_full (G_OBJECT (application), "miu-pending-locations", pending, g_free);
    g_signal_connect (application, "window-added", G_CALLBACK (browser_window_added), NULL);
    g_signal_connect (application, "open", G_CALLBACK (application_open), NULL);
    g_signal_connect (application, "activate", G_CALLBACK (application_activate), NULL);
    g_signal_connect (application, "command-line", G_CALLBACK (application_command_line), NULL);
    g_dbus_connection_add_filter (g_application_get_dbus_connection (application), file_manager_filter,
                                  application, NULL);
}

static void
miu_nautilus_tabs_class_init (MiuNautilusTabsClass *class G_GNUC_UNUSED)
{
}

static void
miu_nautilus_tabs_class_finalize (MiuNautilusTabsClass *class G_GNUC_UNUSED)
{
}

void
nautilus_module_initialize (GTypeModule *module)
{
    extension_types[0] = g_type_from_name ("MiuNautilusTabs");
    if (extension_types[0] == 0) {
        miu_nautilus_tabs_register_type (module);
        extension_types[0] = miu_nautilus_tabs_get_type ();
    }
}

void
nautilus_module_shutdown (void)
{
}

void
nautilus_module_list_types (const GType **types, int *count)
{
    *types = extension_types;
    *count = G_N_ELEMENTS (extension_types);
}
