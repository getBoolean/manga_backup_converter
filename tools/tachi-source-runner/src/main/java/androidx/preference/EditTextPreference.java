package androidx.preference;

import android.content.Context;
import android.widget.EditText;

public class EditTextPreference extends DialogPreference {
    public interface OnBindEditTextListener {
        void onBindEditText(EditText editText);
    }

    private String text;
    private OnBindEditTextListener bindListener;

    public EditTextPreference(Context context) { super(context); }

    public String getText() { return text; }
    public void setText(String text) { this.text = text; }
    public void setOnBindEditTextListener(OnBindEditTextListener l) { bindListener = l; }
}

