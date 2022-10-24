using Tar, SHA, Inflate

cd("/home/liozou/.julia/dev/CrystalNetsArchive/archives");
run(`tar -cJf archives.tar.xz epinet.arc rcsr.arc zeolites.arc`);
run(`tar -czf archives.tar.gz epinet.arc rcsr.arc zeolites.arc`);
mv("archives.tar.gz", "../archives.tar.gz"; force=true);
mv("archives.tar.xz", "../archives.tar.xz"; force=true);
println("git-tree-sha1: ", Tar.tree_hash(IOBuffer(inflate_gzip("/home/liozou/.julia/dev/CrystalNetsArchive/archives.tar.gz"))));
println("sha256 (tar.xz): ", bytes2hex(open(sha256, "/home/liozou/.julia/dev/CrystalNetsArchive/archives.tar.xz")));
println("sha256 (zip): ", bytes2hex(open(sha256, "/home/liozou/.julia/dev/CrystalNetsArchive/archives.zip")));
