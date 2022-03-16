package dtc

import "core:sys/win32"
import "core:sys/windows"
import "core:intrinsics"
import "core:os"

foreign import user32 "system:User32.lib"

@(default_calling_convention="stdcall")
foreign user32 {
	PostThreadMessageW :: proc(
		idThread: windows.DWORD,
		Msg: windows.UINT,
		wParam: win32.Wparam,
		lParam: win32.Lparam,
	) -> windows.BOOL ---

	FindWindowExW :: proc(
		hWndParent: win32.Hwnd,
		hWndChildAfter: win32.Hwnd,
		lpszClass: windows.LPCWSTR,
		lpszWindow: windows.LPCWSTR,
	) -> win32.Hwnd ---
}

L :: intrinsics.constant_utf16_cstring

_IDI_APPLICATION := rawptr(uintptr(32512))
IDI_APPLICATION := cstring(_IDI_APPLICATION)

The_Baby :: struct {
	dwExStyle:    windows.DWORD,
	lpClassName:  windows.LPCWSTR,
	lpWindowName: windows.LPCWSTR,
	dwStyle:      windows.DWORD,
	X:            windows.c_int,
	Y:            windows.c_int,
	nWidth:       windows.c_int,
	nHeight:      windows.c_int,
	hWndParent:   win32.Hwnd,
	hMenu:        win32.Hmenu,
	hInstance:    win32.Hinstance,
	lpParam:      windows.LPVOID,
}

CREATE_DANGEROUS_WINDOW :: win32.WM_USER + 0x1337
DESTROY_DANGEROUS_WINDOW :: win32.WM_USER + 0x1338

main_thread_ID: windows.DWORD

service_wnd_proc :: proc "std" (window: win32.Hwnd, message: u32, wparam: win32.Wparam, lparam: win32.Lparam) -> (result: win32.Lresult) {
	/* NOTE(casey): This is not really a window handler per se, it's actually just
		 a remote thread call handler. Windows only really has blocking remote thread
		 calls if you register a WndProc for them, so that's what we do.

		 This handles CREATE_DANGEROUS_WINDOW and DESTROY_DANGEROUS_WINDOW, which are
		 just calls that do CreateWindow and DestroyWindow here on this thread when
		 some other thread wants that to happen.
	*/

	switch message {
	case CREATE_DANGEROUS_WINDOW:
		baby := cast(^The_Baby)wparam
		wnd := win32.create_window_ex_w(
			baby.dwExStyle,
			baby.lpClassName,
			baby.lpWindowName,
			baby.dwStyle,
			baby.X,
			baby.Y,
			baby.nWidth,
			baby.nHeight,
			baby.hWndParent,
			baby.hMenu,
			baby.hInstance,
			baby.lpParam,
		)
		result = win32.Lresult(uintptr(wnd))
	case DESTROY_DANGEROUS_WINDOW:
		win32.destroy_window(win32.Hwnd(wparam))
	case:
		result = win32.def_window_proc_w(window, message, wparam, lparam)
	}

	return
}

display_wnd_proc :: proc "std" (window: win32.Hwnd, message: u32, wparam: win32.Wparam, lparam: win32.Lparam) -> (result: win32.Lresult) {
	/* NOTE(casey): This is an example of an actual window procedure. It doesn't do anything
		 but forward things to the main thread, because again, all window messages now occur
		 on the message thread, and presumably we would rather handle everything there.  You
		 don't _have_ to do that - you could choose to handle some of the messages here.
		 But if you did, you would have to actually think about whether there are race conditions
		 with your main thread and all that.  So just PostThreadMessageW()'ing everything gets
		 you out of having to think about it.
	*/

	switch message {
	// NOTE(casey): Mildly annoying, if you want to specify a window, you have
	// to snuggle the params yourself, because Windows doesn't let you forward
	// a god damn window message even though the program IS CALLED WINDOWS. It's
	// in the name! Let me pass it!
	case win32.WM_CLOSE:
		PostThreadMessageW(main_thread_ID, message, win32.Wparam(window), lparam)

	// NOTE(casey): Anything you want the application to handle, forward to the main thread
	// here.
	case win32.WM_MOUSEMOVE, win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP, win32.WM_DESTROY, win32.WM_CHAR:
		PostThreadMessageW(main_thread_ID, message, wparam, lparam)

	case:
		result = win32.def_window_proc_w(window, message, wparam, lparam)
	}

	return
}

main_thread :: proc "stdcall" (param: windows.LPVOID) -> windows.DWORD {
	/* NOTE(Casey): This is your app code. Basically you just do everything the same,
		 but instead of calling CreateWindow/DestroyWindow, you use SendMessage to
		 do it on the other thread, using the CREATE_DANGEROUS_WINDOW and DESTROY_DANGEROUS_WINDOW
		 user messages.  Otherwise, everything proceeds as normal.
	*/
	instance := win32.Hinstance(windows.GetModuleHandleW(nil))

	service_window := win32.Hwnd(param)

	window_class: win32.Wnd_Class_Ex_W = {
		size = size_of(win32.Wnd_Class_Ex_W),
		//style = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW,
		wnd_proc = display_wnd_proc,
		instance = instance,
		icon = win32.load_icon_a(nil, IDI_APPLICATION),
		cursor = win32.load_cursor_a(nil, win32.IDC_ARROW),
		background = win32.Hbrush(win32.get_stock_object(win32.BLACK_BRUSH)),
		class_name = L("Dangerous Class"),
	}
	win32.register_class_ex_w(&window_class)

	baby: The_Baby = {
		dwExStyle = 0,
		lpClassName = window_class.class_name,
		lpWindowName = L("Dangerous Window"),
		dwStyle = win32.WS_OVERLAPPEDWINDOW | win32.WS_VISIBLE,
		X = win32.CW_USEDEFAULT,
		Y = win32.CW_USEDEFAULT,
		nWidth = win32.CW_USEDEFAULT,
		nHeight = win32.CW_USEDEFAULT,
		hInstance = window_class.instance,
	}
	result := win32.send_message_w(service_window, CREATE_DANGEROUS_WINDOW, cast(win32.Wparam)&baby, 0)
	this_would_be_the_handle_if_you_cared := win32.Hwnd(uintptr(result))
	_ = this_would_be_the_handle_if_you_cared

	x: i32
	for {
		message: win32.Msg
		for win32.peek_message_w(&message, nil, 0, 0, win32.PM_REMOVE) {
			switch message.message {
			case win32.WM_CHAR:
				win32.send_message_w(service_window, CREATE_DANGEROUS_WINDOW, cast(win32.Wparam)&baby, 0)

			case win32.WM_CLOSE:
				win32.send_message_w(service_window, DESTROY_DANGEROUS_WINDOW, message.wparam, 0)
			}
		}

		mid_point := (x%(64*1024))/64
		x += 1

		window_count: i32
		for window := FindWindowExW(nil, nil, window_class.class_name, nil)
		window != nil;
		window = FindWindowExW(nil, window, window_class.class_name, nil) {
			client: win32.Rect = ---
			win32.get_client_rect(window, &client)
			dc := win32.get_dc(window)

			win32.pat_blt(dc, 0, 0, mid_point, client.bottom, win32.BLACKNESS)
			if client.right > mid_point {
				win32.pat_blt(dc, mid_point, 0, client.right - mid_point, client.bottom, win32.WHITENESS)
			}
			win32.release_dc(window, dc)

			window_count += 1
		}

		if window_count == 0 do break
	}

	os.exit(0)
}

main :: proc() {
	instance := win32.Hinstance(windows.GetModuleHandleW(nil))
	assert(instance != nil, "Failed to detect default instance")

	/* NOTE(casey): At startup, you create one hidden window used to handle requests
		 to create or destroy windows.  There's nothing special about this window; it
		 only exists because Windows doesn't have a way to do a remote thread call without
		 a window handler.  You could instead just do this with your own synchronization
		 primitives if you wanted - this is just the easiest way to do it on Windows
		 because they've already built it for you.
	*/

	window_class: win32.Wnd_Class_Ex_W = {
		size = size_of(win32.Wnd_Class_Ex_W),
		wnd_proc = service_wnd_proc,
		instance = instance,
		icon = win32.load_icon_a(nil, IDI_APPLICATION),
		cursor = win32.load_cursor_a(nil, win32.IDC_ARROW),
		background = win32.Hbrush(win32.get_stock_object(win32.BLACK_BRUSH)),
		class_name = L("DTCClass"),
	}
	win32.register_class_ex_w(&window_class)

	service_window := win32.create_window_ex_w(
		0, window_class.class_name, L("DTCService"), 0,
		win32.CW_USEDEFAULT, win32.CW_USEDEFAULT,
		win32.CW_USEDEFAULT, win32.CW_USEDEFAULT,
		nil, nil, window_class.instance, nil,
	)

	// NOTE(casey): Once the service window is created, you can start the main thread,
	// which is where all your app code would actually happen.
	windows.CreateThread(nil, 0, main_thread, service_window, 0, &main_thread_ID)

	// NOTE(casey): This thread can just idle for the rest of the run, forwarding
	// messages to the main thread that it thinks the main thread wants.
	for {
		message: win32.Msg
		win32.get_message_w(&message, nil, 0, 0)
		win32.translate_message(&message)

		switch message.message {
		case win32.WM_CHAR, win32.WM_KEYDOWN, win32.WM_QUIT, win32.WM_SIZE:
			PostThreadMessageW(main_thread_ID, message.message, message.wparam, message.lparam)
		case:
			win32.dispatch_message_w(&message)
		}
	}

}
