namespace ParaphraseTool.Core
{
    /// <summary>What the overlay's buttons can ask the server to do with the field text.</summary>
    public enum TextAction
    {
        /// <summary>Rewrite in the same language, following the Paraphrase instruction from Settings.</summary>
        Paraphrase,

        /// <summary>Translate into natural, paraphrased English whatever the original language.</summary>
        TranslateToEnglish,
    }

    public static class TextActionInfo
    {
        public static string Verb(this TextAction action) =>
            action == TextAction.TranslateToEnglish ? "Translate" : "Paraphrase";

        public static string Path(this TextAction action) =>
            action == TextAction.TranslateToEnglish ? "/api/translate" : "/api/paraphrase";
    }
}
