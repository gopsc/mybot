@Action
net.timeout net.num_recv;
       1000          512;
@

@Action
net.connect;
          1;
@

@Action
net.send_hex;
$("00FF80");
@

@Action
net.recv_hex;
           1;
@

@Action
net.send_str;
 $("你好");
@

@Action
net.recv_str;
           1;
@

@Action
net.close;
        1;
@
