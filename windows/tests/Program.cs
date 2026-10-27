// Testa o motor: 2 cartões em paralelo, nomes, duplicados, separar por cartão, PDF e ASC MHL.
using Acervo;

var T = args[0];
var split = args[1] == "1";
var v = Config.Vertice();
v.Inbox = Path.Combine(T, "inbox"); v.Backups = [Path.Combine(T, "b1")]; v.SplitByCard = split;
var title = split ? "SEPARADO" : "JUNTO";
var name = Capture.FolderName(v, new DateTime(2026, 10, 26), title);
Capture.Create(name, v);
var cap = Capture.List(v).First(c => c.Name == name);
Console.WriteLine($"captação: {cap.Name} | título={cap.Title} data={cap.Date:yyyy-MM-dd}");
var files = CardScanner.Scan([Path.Combine(T, "CAM A"), Path.Combine(T, "CAM B")], v);
var plan = ImportPlan.Make(files, v.ReceivingFolders.Select(f => f.Id).ToHashSet(), cap, v, v.Backups);
var maxCards = 0;
var r = new Copier().Run(plan, p => { if (p.Cards > maxCards) maxCards = p.Cards; });
r.Warnings = Reports.Write(r, v);
Console.WriteLine($"[{name}] cartões em paralelo={maxCards} copiados={r.Verified} dup={r.Skipped} falhas={string.Join("; ", r.Failures)} avisos={string.Join("; ", r.Warnings)}");
foreach (var e in r.Entries) Console.WriteLine($"   {e.CardName} {Path.GetFileName(e.Source)} -> {Path.GetRelativePath(v.Inbox, e.Targets[0])} {e.Hash}");
