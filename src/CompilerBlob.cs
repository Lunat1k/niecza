using System;
using System.Collections;
using System.Collections.Generic;
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
                string[] sa = new string[ia.Length];
                Array.Copy(ia, sa, ia.Length);
                string[] sar = Builtins.UnboxLoS(Kernel.RunInferior(
                            Downcaller.upcall_cb.Fetch().Invoke(
                                Kernel.GetInferiorRoot(),
                                new Variable[] { Builtins.BoxLoS(sa) }, null)));
                object[] iar = new object[sar.Length];
                Array.Copy(sar, iar, sar.Length);
                return iar;
            }
        }
    }

    public class Downcaller {
        static AppDomain subDomain;
        internal static Variable upcall_cb;
        static IDictionary responder;
        static P6any UnitP, StaticSubP, TypeP;
        // Better, but still fudgy.  Relies too much on path structure.
        public static void InitSlave(Variable cb, Variable unit,
                Variable staticSub, Variable type) {
            if (subDomain != null) return;

            UnitP = unit.Fetch();
            StaticSubP = staticSub.Fetch();
            TypeP = type.Fetch();

            AppDomainSetup ads = new AppDomainSetup();
            string obj = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, Path.Combine("..", "obj")));
            ads.ApplicationBase = obj;
            string backend = Path.Combine(obj, "Kernel.dll");
            subDomain = AppDomain.CreateDomain("zyg", null, ads);
            upcall_cb = cb;
            responder = (IDictionary)
                subDomain.CreateInstanceFromAndUnwrap(backend,
                        "Niecza.CLRBackend.DowncallReceiver");
            RawDowncall("set_parent", AppDomain.CurrentDomain);
        }
        public static object RawDowncall(params object[] args) {
            return responder[args];
        }
        public static Variable DownCall(Variable list) {
            List<object> lo = new List<object>();
            VarDeque it = Builtins.start_iter(list);
            while (Kernel.IterHasFlat(it, true)) {
                Variable v = it.Shift();
                P6any o = v.Fetch();
                if (o is BoxObject<object>)
                    lo.Add(Kernel.UnboxAny<object>(o));
                else if (o.IsDefined()) {
                    if (o.Isa(Kernel.StrMO))
                        lo.Add((string) o.mo.mro_raw_Str.Get(v));
                    else if (o.Isa(Kernel.BoolMO))
                        lo.Add((bool) o.mo.mro_raw_Bool.Get(v));
                    else
                        lo.Add((int) o.mo.mro_raw_Numeric.Get(v));
                } else
                    lo.Add(null);
            }

            return DCResult(RawDowncall(lo.ToArray()));
        }

        static Variable DCResult(object r) {
            if (r == null) return Kernel.AnyMO.typeVar;
            else if (r is string) return Kernel.BoxAnyMO((string)r, Kernel.StrMO);
            else if (r is int) return Builtins.MakeInt((int)r);
            else if (r is bool) return ((bool)r) ? Kernel.TrueV : Kernel.FalseV;
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
                    (t == "unit") ? UnitP : null;
                return Kernel.BoxAnyMO(r, pr.mo);
            }
        }
    }
}