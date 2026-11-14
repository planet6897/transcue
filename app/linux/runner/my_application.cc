#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <locale.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

// "Transcue · AI 동영상 플레이어"
static const char kWindowTitle[] =
    "Transcue \u00B7 AI \uB3D9\uC601\uC0C1 \uD50C\uB808\uC774\uC5B4";

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // 창 위에 끌어다 놓은 링크·파일을 Dart로 알린다 (transcue/drop)
  FlMethodChannel* drop_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// 브라우저에서 끌어 온 링크(YouTube)나 동영상 파일을 창 위에 놓았을 때.
// 파일은 경로, 링크는 주소, 그 밖의 글은 그대로 넘긴다. 무엇을 열지는
// Dart(pickDropped)가 고른다.
static void drag_data_received_cb(GtkWidget* widget,
                                  GdkDragContext* context,
                                  gint x,
                                  gint y,
                                  GtkSelectionData* data,
                                  guint info,
                                  guint time,
                                  gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(FlValue) items = fl_value_new_list();
  g_auto(GStrv) uris = gtk_selection_data_get_uris(data);
  if (uris != nullptr) {
    for (gchar** uri = uris; *uri != nullptr; uri++) {
      g_autofree gchar* path = g_str_has_prefix(*uri, "file://")
                                   ? g_filename_from_uri(*uri, nullptr, nullptr)
                                   : nullptr;
      fl_value_append_take(items,
                           fl_value_new_string(path != nullptr ? path : *uri));
    }
  } else {
    g_autofree guchar* text = gtk_selection_data_get_text(data);
    if (text != nullptr) {
      fl_value_append_take(
          items, fl_value_new_string(reinterpret_cast<const gchar*>(text)));
    }
  }
  gboolean accepted = fl_value_get_length(items) > 0;
  if (accepted && self->drop_channel != nullptr) {
    fl_method_channel_invoke_method(self->drop_channel, "drop", items, nullptr,
                                    nullptr, nullptr);
    gtk_window_present(GTK_WINDOW(gtk_widget_get_toplevel(widget)));
  }
  gtk_drag_finish(context, accepted, FALSE, time);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, kWindowTitle);
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, kWindowTitle);
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // libmpv(media_kit)는 숫자 로캘이 "C"여야 한다. GTK가 시작하면서 시스템 로캘로
  // 바꿔 놓으므로 여기서 되돌린다 (소수점이 쉼표인 로캘에서 재생이 실패함).
  setlocale(LC_NUMERIC, "C");

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->drop_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "transcue/drop", FL_METHOD_CODEC(codec));
  gtk_drag_dest_set(GTK_WIDGET(view), GTK_DEST_DEFAULT_ALL, nullptr, 0,
                    static_cast<GdkDragAction>(GDK_ACTION_COPY |
                                               GDK_ACTION_LINK));
  gtk_drag_dest_add_uri_targets(GTK_WIDGET(view));
  gtk_drag_dest_add_text_targets(GTK_WIDGET(view));
  g_signal_connect(view, "drag-data-received",
                   G_CALLBACK(drag_data_received_cb), self);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->drop_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
