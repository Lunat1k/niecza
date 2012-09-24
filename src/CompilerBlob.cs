using System;
using System.Reflection;
using System.Collections;
using System.Collections.Generic;
using System.Text;
using System.Security.Cryptography;
using System.IO;

namespace Niecza {
    public abstract class CallReceiver : MarshalByRefObject, IDictionary {
        public bool IsFixedSize { get { return false; } }
        public bool IsReadOnly { get { return false; } }
        public bool IsSynchronized { get { return false; } }
        public int Count { get { return 0; } }
        public object SyncRoot { get { return null; } }
        public ICollection Keys { get { return null; } }
        public ICollection Values { get { return null; } }
        public void Add(object a, object b) { }
        public void Clear() { }
        public IDictionaryEnumerator GetEnumerator() { return null; }
        IEnumerator IEnumerable.GetEnumerator() { return null; }
        public bool Contains(object a) { return false; }
        public void CopyTo(Array a, int offs) { }
        public void Remove(object a) { }
        public abstract object this[object i] { get; set; }
    }

    public class UpcallReceiver : CallReceiver {
        public override object this[object i] {
            set { }
            get {
                object[] ia = (object[]) i;
                Variable[] va = new Variable[ia.Length];
                for (int ix = 0; ix < ia.Length; ix++)
                    va[ix] = Downcaller.DCResult(ia[ix]);
                try {
                    Variable vr = Kernel.RunInferior(
                            Downcaller.upcall_cb.Fetch().Invoke(
                                Kernel.GetInferiorRoot(), va, null));
                    return Downcaller.DCArg(vr);
                } catch (Exception ex) {
                    return new Exception(ex.ToString());
                }
            }
        }
    }

    public class Downcaller {
        internal static Variable upcall_cb;
        static Variable TrueV, FalseV;
        static IDictionary responder;
        static P6any UnitP, StaticSubP, TypeP, ParamP, ValueP;
        static STable StrMO, NumMO, ListMO, AnyMO, BoolMO;
        static string obj_dir;

        // let the CLR load assemblies from obj/ too
        static Assembly ObjLoader(object source, ResolveEventArgs e) {
            string name = e.Name;
            if (name.IndexOf(',') >= 0)
                name = name.Substring(0, name.IndexOf(','));
            string file = Path.Combine(obj_dir, name + ".dll");
            if (File.Exists(file))
                return Assembly.LoadFrom(file);
            else
                return null;
        }
        // Better, but still fudgy.  Relies too much on path structure.
        public static void InitSlave(Variable cb, P6any cmd_obj_dir, Variable unit,
                Variable staticSub, Variable type, Variable param, Variable value,
                Variable str, Variable num, Variable @true, Variable @false,
                Variable list, Variable any, Variable @bool) {
            if (responder != null) return;

            UnitP = unit.Fetch();
            StaticSubP = staticSub.Fetch();
            TypeP = type.Fetch();
            ParamP = param.Fetch();
            ValueP = value.Fetch();
            StrMO = str.Fetch().mo;
            NumMO = num.Fetch().mo;
            TrueV = @true;
            FalseV = @false;
            ListMO = list.Fetch().mo;
            AnyMO = any.Fetch().mo;
            BoolMO = @bool.Fetch().mo;

            obj_dir = Path.GetFullPath(cmd_obj_dir.IsDefined() ?
                    cmd_obj_dir.mo.mro_raw_Str.Get(cmd_obj_dir) :
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        "NieczaModuleCache"));

            Directory.CreateDirectory(obj_dir); // like mkdir -p

            if (!File.Exists(Path.Combine(obj_dir, "Run.Kernel.dll"))) {
                File.Copy(
                    Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Run.Kernel.dll"),
                    Path.Combine(obj_dir, "Run.Kernel.dll")
                );
            }

            AppDomain.CurrentDomain.AssemblyResolve += ObjLoader;

            upcall_cb = cb;
            responder = (IDictionary) Activator.CreateInstance(Type.GetType(
                    "Niecza.CLRBackend.DowncallReceiver,Run.Kernel", true));
            RawDowncall("set_binding", obj_dir, new UpcallReceiver());
        }
        public static object RawDowncall(params object[] args) {
            return responder[args];
        }

        internal static object DCArg(Variable v) {
            P6any o = v.Fetch();
            if (o is BoxObject<object>)
                return Kernel.UnboxAny<object>(o);
            else if (o.IsDefined()) {
                if (o.Isa(StrMO))
                    return (string) o.mo.mro_raw_Str.Get(v);
                else if (o.Isa(BoolMO))
                    return (bool) o.mo.mro_raw_Bool.Get(v);
                else if (o.Isa(NumMO)) {
                    double d = Kernel.UnboxAny<double>(o);
                    if ((d % 1) == 0 && d <= int.MaxValue && d >= int.MinValue)
                        return (object)(int)d;
                    return (object)d;
                } else if (o.Isa(ListMO)) {
                    VarDeque it = o.mo.mro_raw_iterator.Get(v);
                    var lo = new List<object>();
                    while (Kernel.IterHasFlat(it, true))
                        lo.Add(DCArg(it.Shift()));
                    return lo.ToArray();
                } else
                    return (int) o.mo.mro_raw_Numeric.Get(v);
            } else
                return null;
        }

        public static Variable DownCall(Variable list) {
            List<object> lo = new List<object>();
            VarDeque it = Builtins.start_iter(list);
            while (Kernel.IterHasFlat(it, true))
                lo.Add(DCArg(it.Shift()));

            return DCResult(RawDowncall(lo.ToArray()));
        }

        internal static Variable DCResult(object r) {
            if (r == null) return AnyMO.typeObj;
            else if (r is string) return Kernel.BoxAnyMO((string)r, StrMO);
            else if (r is int) return Builtins.MakeInt((int)r);
            else if (r is bool) return ((bool)r) ? TrueV : FalseV;
            else if (r is Exception) throw new NieczaException(((Exception)r).Message);
            else if (r is object[]) {
                object[] ra = (object[])r;
                Variable[] ba = new Variable[ra.Length];
                for (int i = 0; i < ba.Length; i++) ba[i] = DCResult(ra[i]);
                return Builtins.MakeParcel(ba);
            }
            else {
                string t = (string)RawDowncall("gettype", r);
                P6any pr = (t == "type") ? TypeP :
                    (t == "sub") ? StaticSubP :
                    (t == "param") ? ParamP :
                    (t == "value") ? ValueP :
                    (t == "unit") ? UnitP : AnyMO.typeObj;
                return Kernel.BoxAnyMO(r, pr.mo);
            }
        }

        static void SerializeNam(Variable v, StringBuilder sb,
                List<object> refs) {

            P6any o = v.Fetch();
            if (o is BoxObject<int>) { /* includes bool */
                sb.Append(Kernel.UnboxAny<int>(o));
            } else if (o is BoxObject<double>) {
                sb.Append(Utils.N2S(Kernel.UnboxAny<double>(o)));
            } else if (o is BoxObject<string>) {
                string s = Kernel.UnboxAny<string>(o);
                sb.Append('"');
                foreach (char c in s) {
                    if (c >= ' ' && c <= '~' && c != '\\' && c != '"')
                        sb.Append(c);
                    else {
                        sb.Append("\\u");
                        sb.AppendFormat("{0:X4}", (int)c);
                    }
                }
                sb.Append('"');
            } else if (!o.IsDefined()) {
                sb.Append("null");
            } else if (o.Isa(ListMO)) {
                VarDeque d = o.mo.mro_raw_iterator.Get(v);
                bool comma = false;
                sb.Append('[');
                while (Kernel.IterHasFlat(d, true)) {
                    if (comma) sb.Append(',');
                    SerializeNam(d.Shift(), sb, refs);
                    comma = true;
                }
                sb.Append(']');
            } else if (o is BoxObject<object>) {
                sb.Append('!');
                sb.Append(refs.Count);
                refs.Add(Kernel.UnboxAny<object>(o));
            } else {
                throw new NieczaException("weird object in sub_finish " + o.mo.name);
            }
        }

        public static Variable Finish(Variable si, Variable nam) {
            StringBuilder sb = new StringBuilder();
            List<object> refs = new List<object>();
            SerializeNam(nam, sb, refs);
            object[] args = new object[refs.Count + 3];
            args[0] = "sub_finish";
            args[1] = Kernel.UnboxAny<object>(si.Fetch());
            args[2] = sb.ToString();
            refs.CopyTo(args, 3);
            return DCResult(RawDowncall(args));
        }

        public static string DoHash(string input) {
            HashAlgorithm sha = SHA256.Create();
            byte[] ibytes = new UTF8Encoding().GetBytes(input);
            byte[] hash = sha.ComputeHash(ibytes);
            char[] buf = new char[hash.Length * 2];
            for (int i = 0; i < hash.Length; i++) {
                buf[i*2]   = "0123456789abcdef"[hash[i] >> 4];
                buf[i*2+1] = "0123456789abcdef"[hash[i] & 15];
            }
            return new string(buf);
        }

        public static string ExecName() {
            return Assembly.GetEntryAssembly().Location;
        }

        static Dictionary<P6any,Dictionary<P6any,Variable>> role_cache =
            new Dictionary<P6any,Dictionary<P6any,Variable>>();
        public static Variable CachedBut(P6any but, Variable v1, Variable v2) {
            P6any a1 = v1.Fetch();
            P6any a2 = v2.Fetch();
            Dictionary<P6any,Variable> subcache;
            if (!role_cache.TryGetValue(a1, out subcache))
                role_cache[a1] = subcache = new Dictionary<P6any,Variable>();
            Variable var;
            if (subcache.TryGetValue(a2, out var))
                return var;

            // Mega-Hack - stop lots of internal data from being retained by
            // CALLER pointers
            Kernel.SetTopFrame(null);

            var = Kernel.RunInferior(but.Invoke(Kernel.GetInferiorRoot(),
                new [] { v1, v2 }, null));
            return subcache[a2] = var;
        }

        public static Variable PruneMatch(Variable vr) {
            Cursor c = (Cursor)vr.Fetch();
            // remove as much as possible - don't call this if you still need
            // the match!
            if (c.feedback != null) {
                c.feedback.CommitRule();
                c.feedback.bt = null;
                c.feedback.st = new State();
                c.feedback.ast = null;
            }

            for (CapInfo it = c.captures; it != null; it = it.prev) {
                if (it.cap != null && it.cap.Fetch() is Cursor)
                    PruneMatch(it.cap);
            }

            c.captures = null;
            c.feedback = null;
            c.ast = null;
            c.xact = null;
            c.nstate = null;
            return vr;
        }
    }
}
