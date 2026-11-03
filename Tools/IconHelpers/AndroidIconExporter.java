package dev.ekko.simlaunch;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.Looper;
import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.Method;
import org.json.JSONObject;

/** Read-only shell helper. Batches reuse one VM/context; no app code or activities are loaded. */
public final class AndroidIconExporter {
    private static String encode(byte[] value) { return Base64.encodeToString(value, Base64.NO_WRAP); }
    private static JSONObject read(Context system, Method create, Object handle, String name) throws Exception {
        if (!name.matches("[A-Za-z0-9_][A-Za-z0-9_.-]{0,254}")) throw new IllegalArgumentException("package");
        Context context = (Context) create.invoke(system, name, Context.CONTEXT_IGNORE_SECURITY, handle);
        ApplicationInfo info = context.getApplicationInfo();
        if (!name.equals(info.packageName)) throw new IllegalStateException("package mismatch");
        Drawable drawable;
        if (info.icon != 0) drawable = info.loadIcon(context.getPackageManager());
        else {
            android.content.Intent launch = context.getPackageManager().getLaunchIntentForPackage(name);
            if (launch == null || launch.getComponent() == null) throw new IllegalStateException("no declared application icon");
            android.content.pm.ActivityInfo activity = context.getPackageManager().getActivityInfo(launch.getComponent(), 0);
            if (activity.icon == 0) throw new IllegalStateException("no declared application icon");
            drawable = activity.loadIcon(context.getPackageManager());
        }
        if (drawable == null) throw new IllegalStateException("no drawable");
        Bitmap image = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888);
        try {
            drawable.setBounds(0, 0, 128, 128); drawable.draw(new Canvas(image));
            ByteArrayOutputStream png = new ByteArrayOutputStream();
            if (!image.compress(Bitmap.CompressFormat.PNG, 100, png)) throw new IllegalStateException("PNG encoding");
            JSONObject result = new JSONObject(); result.put("id", name); result.put("png", encode(png.toByteArray()));
            CharSequence label = info.loadLabel(context.getPackageManager());
            if (label != null) result.put("label", label.toString());
            return result;
        } finally { image.recycle(); }
    }
    public static void main(String[] args) {
        try {
            boolean batch = args.length >= 3 && args[0].equals("--batch");
            if ((!batch && args.length != 2) || args.length > 10 || !args[1].matches("[0-9]+")) throw new IllegalArgumentException("arguments");
            if (Looper.myLooper() == null) Looper.prepare();
            Class<?> threadClass = Class.forName("android.app.ActivityThread");
            Object thread = threadClass.getMethod("systemMain").invoke(null);
            Context system = (Context) threadClass.getMethod("getSystemContext").invoke(thread);
            Class<?> handleClass = Class.forName("android.os.UserHandle");
            Object handle = handleClass.getMethod("of", int.class).invoke(null, Integer.parseInt(args[1]));
            Method create = Context.class.getMethod("createPackageContextAsUser", String.class, int.class, handleClass);
            if (batch) {
                for (int i = 2; i < args.length; i++) {
                    JSONObject result;
                    try { result = read(system, create, handle, args[i]); }
                    catch (Throwable error) { result = new JSONObject(); result.put("id", args[i]); result.put("error", error.toString()); }
                    System.out.println("SIMLAUNCH_RECORD:" + encode(result.toString().getBytes("UTF-8")));
                }
            } else {
                JSONObject result = read(system, create, handle, args[0]);
                System.out.println("SIMLAUNCH_ICON:" + result.getString("png"));
                if (result.has("label")) System.out.println("SIMLAUNCH_LABEL:" + encode(result.getString("label").getBytes("UTF-8")));
            }
        } catch (Throwable error) {
            Throwable cause = error.getCause() != null ? error.getCause() : error;
            System.err.println("SIMLAUNCH_ERROR:" + cause.toString()); System.exit(1);
        }
    }
}
