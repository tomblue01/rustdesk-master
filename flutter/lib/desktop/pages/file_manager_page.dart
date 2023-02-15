import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:flutter_hbb/desktop/widgets/list_search_action_listener.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:wakelock/wakelock.dart';
import '../../consts.dart';
import '../../desktop/widgets/material_mod_popup_menu.dart' as mod_menu;

import '../../common.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../widgets/popup_menu.dart';

/// status of location bar
enum LocationStatus {
  /// normal bread crumb bar
  bread,

  /// show path text field
  pathLocation,

  /// show file search bar text field
  fileSearchBar
}

/// The status of currently focused scope of the mouse
enum MouseFocusScope {
  /// Mouse is in local field.
  local,

  /// Mouse is in remote field.
  remote,

  /// Mouse is not in local field, remote neither.
  none
}

class FileManagerPage extends StatefulWidget {
  const FileManagerPage({Key? key, required this.id}) : super(key: key);
  final String id;

  @override
  State<StatefulWidget> createState() => _FileManagerPageState();
}

class _FileManagerPageState extends State<FileManagerPage>
    with AutomaticKeepAliveClientMixin {
  final _localSelectedItems = SelectedItems();
  final _remoteSelectedItems = SelectedItems();

  final _locationStatusLocal = LocationStatus.bread.obs;
  final _locationStatusRemote = LocationStatus.bread.obs;
  final _locationNodeLocal = FocusNode(debugLabel: "locationNodeLocal");
  final _locationNodeRemote = FocusNode(debugLabel: "locationNodeRemote");
  final _locationBarKeyLocal = GlobalKey(debugLabel: "locationBarKeyLocal");
  final _locationBarKeyRemote = GlobalKey(debugLabel: "locationBarKeyRemote");
  final _searchTextLocal = "".obs;
  final _searchTextRemote = "".obs;
  final _breadCrumbScrollerLocal = ScrollController();
  final _breadCrumbScrollerRemote = ScrollController();
  final _mouseFocusScope = Rx<MouseFocusScope>(MouseFocusScope.none);
  final _keyboardNodeLocal = FocusNode(debugLabel: "keyboardNodeLocal");
  final _keyboardNodeRemote = FocusNode(debugLabel: "keyboardNodeRemote");
  final _listSearchBufferLocal = TimeoutStringBuffer();
  final _listSearchBufferRemote = TimeoutStringBuffer();

  /// [_lastClickTime], [_lastClickEntry] help to handle double click
  int _lastClickTime =
      DateTime.now().millisecondsSinceEpoch - bind.getDoubleClickTime() - 1000;
  Entry? _lastClickEntry;

  final _dropMaskVisible = false.obs; // TODO impl drop mask
  final _overlayKeyState = OverlayKeyState();

  ScrollController getBreadCrumbScrollController(bool isLocal) {
    return isLocal ? _breadCrumbScrollerLocal : _breadCrumbScrollerRemote;
  }

  GlobalKey getLocationBarKey(bool isLocal) {
    return isLocal ? _locationBarKeyLocal : _locationBarKeyRemote;
  }

  late FFI _ffi;

  FileModel get model => _ffi.fileModel;

  SelectedItems getSelectedItems(bool isLocal) {
    return isLocal ? _localSelectedItems : _remoteSelectedItems;
  }

  @override
  void initState() {
    super.initState();
    _ffi = FFI();
    _ffi.start(widget.id, isFileTransfer: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ffi.dialogManager
          .showLoading(translate('Connecting...'), onCancel: closeConnection);
    });
    Get.put(_ffi, tag: 'ft_${widget.id}');
    if (!Platform.isLinux) {
      Wakelock.enable();
    }
    debugPrint("File manager page init success with id ${widget.id}");
    model.onDirChanged = breadCrumbScrollToEnd;
    // register location listener
    _locationNodeLocal.addListener(onLocalLocationFocusChanged);
    _locationNodeRemote.addListener(onRemoteLocationFocusChanged);
    _ffi.dialogManager.setOverlayState(_overlayKeyState);
  }

  @override
  void dispose() {
    model.onClose().whenComplete(() {
      _ffi.close();
      _ffi.dialogManager.dismissAll();
      if (!Platform.isLinux) {
        Wakelock.disable();
      }
      Get.delete<FFI>(tag: 'ft_${widget.id}');
      _locationNodeLocal.removeListener(onLocalLocationFocusChanged);
      _locationNodeRemote.removeListener(onRemoteLocationFocusChanged);
      _locationNodeLocal.dispose();
      _locationNodeRemote.dispose();
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Overlay(key: _overlayKeyState.key, initialEntries: [
      OverlayEntry(builder: (_) {
        return ChangeNotifierProvider.value(
            value: _ffi.fileModel,
            child: Consumer<FileModel>(builder: (context, model, child) {
              return Scaffold(
                backgroundColor: Theme.of(context).backgroundColor,
                body: Row(
                  children: [
                    Flexible(flex: 3, child: body(isLocal: true)),
                    Flexible(flex: 3, child: body(isLocal: false)),
                    Flexible(flex: 2, child: statusList())
                  ],
                ),
              );
            }));
      })
    ]);
  }

  Widget menu({bool isLocal = false}) {
    var menuPos = RelativeRect.fill;

    final List<MenuEntryBase<String>> items = [
      MenuEntrySwitch<String>(
        switchType: SwitchType.scheckbox,
        text: translate("Show Hidden Files"),
        getter: () async {
          return model.getCurrentShowHidden(isLocal);
        },
        setter: (bool v) async {
          model.toggleShowHidden(local: isLocal);
        },
        padding: kDesktopMenuPadding,
        dismissOnClicked: true,
      ),
      MenuEntryButton(
          childBuilder: (style) => Text(translate("Select All"), style: style),
          proc: () => setState(() => getSelectedItems(isLocal)
              .selectAll(model.getCurrentDir(isLocal).entries)),
          padding: kDesktopMenuPadding,
          dismissOnClicked: true),
      MenuEntryButton(
          childBuilder: (style) =>
              Text(translate("Unselect All"), style: style),
          proc: () => setState(() => getSelectedItems(isLocal).clear()),
          padding: kDesktopMenuPadding,
          dismissOnClicked: true)
    ];

    return Listener(
        onPointerDown: (e) {
          final x = e.position.dx;
          final y = e.position.dy;
          menuPos = RelativeRect.fromLTRB(x, y, x, y);
        },
        child: IconButton(
          icon: const Icon(Icons.more_vert),
          splashRadius: kDesktopIconButtonSplashRadius,
          onPressed: () => mod_menu.showMenu(
            context: context,
            position: menuPos,
            items: items
                .map((e) => e.build(
                    context,
                    MenuConfig(
                        commonColor: CustomPopupMenuTheme.commonColor,
                        height: CustomPopupMenuTheme.height,
                        dividerHeight: CustomPopupMenuTheme.dividerHeight)))
                .expand((i) => i)
                .toList(),
            elevation: 8,
          ),
        ));
  }

  Widget body({bool isLocal = false}) {
    final scrollController = ScrollController();
    return Container(
      decoration: BoxDecoration(border: Border.all(color: Colors.black26)),
      margin: const EdgeInsets.all(16.0),
      padding: const EdgeInsets.all(8.0),
      child: DropTarget(
        onDragDone: (detail) => handleDragDone(detail, isLocal),
        onDragEntered: (enter) {
          _dropMaskVisible.value = true;
        },
        onDragExited: (exit) {
          _dropMaskVisible.value = false;
        },
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          headTools(isLocal),
          Expanded(
              child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _buildFileList(context, isLocal, scrollController),
              )
            ],
          )),
        ]),
      ),
    );
  }

  Widget _buildFileList(
      BuildContext context, bool isLocal, ScrollController scrollController) {
    final fd = model.getCurrentDir(isLocal);
    final entries = fd.entries;
    final selectedEntries = getSelectedItems(isLocal);

    return MouseRegion(
      onEnter: (evt) {
        _mouseFocusScope.value =
            isLocal ? MouseFocusScope.local : MouseFocusScope.remote;
        if (isLocal) {
          _keyboardNodeLocal.requestFocus();
        } else {
          _keyboardNodeRemote.requestFocus();
        }
      },
      onExit: (evt) {
        _mouseFocusScope.value = MouseFocusScope.none;
      },
      child: ListSearchActionListener(
        node: isLocal ? _keyboardNodeLocal : _keyboardNodeRemote,
        buffer: isLocal ? _listSearchBufferLocal : _listSearchBufferRemote,
        onNext: (buffer) {
          debugPrint("searching next for $buffer");
          assert(buffer.length == 1);
          assert(selectedEntries.length <= 1);
          var skipCount = 0;
          if (selectedEntries.items.isNotEmpty) {
            final index = entries.indexOf(selectedEntries.items.first);
            if (index < 0) {
              return;
            }
            skipCount = index + 1;
          }
          var searchResult = entries
              .skip(skipCount)
              .where((element) => element.name.startsWith(buffer));
          if (searchResult.isEmpty) {
            // cannot find next, lets restart search from head
            searchResult =
                entries.where((element) => element.name.startsWith(buffer));
          }
          if (searchResult.isEmpty) {
            setState(() {
              getSelectedItems(isLocal).clear();
            });
            return;
          }
          _jumpToEntry(
              isLocal, searchResult.first, scrollController,
              kDesktopFileTransferRowHeight, buffer);
        },
        onSearch: (buffer) {
          debugPrint("searching for $buffer");
          final selectedEntries = getSelectedItems(isLocal);
          final searchResult =
              entries.where((element) => element.name.startsWith(buffer));
          selectedEntries.clear();
          if (searchResult.isEmpty) {
            setState(() {
              getSelectedItems(isLocal).clear();
            });
            return;
          }
          _jumpToEntry(
              isLocal, searchResult.first, scrollController,
              kDesktopFileTransferRowHeight, buffer);
        },
        child: ObxValue<RxString>(
          (searchText) {
            final filteredEntries = searchText.isNotEmpty
                ? entries.where((element) {
                    return element.name.contains(searchText.value);
                  }).toList(growable: false)
                : entries;
            final rows = filteredEntries.map((entry) {
                final sizeStr =
                    entry.isFile ? readableFileSize(entry.size.toDouble()) : "";
                final lastModifiedStr = entry.isDrive
                    ? " "
                    : "${entry.lastModified().toString().replaceAll(".000", "")}   ";
              final isSelected = selectedEntries.contains(entry);
              return SizedBox(
                key: ValueKey(entry.name),
                height: kDesktopFileTransferRowHeight,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    const Divider(
                      height: 1,
                    ),
                    Expanded(
                      child: Ink(
                        decoration: isSelected
                            ? BoxDecoration(color: Theme.of(context).hoverColor)
                            : null,
                        child: InkWell(
                          child: Row(children: [
                            GestureDetector(
                              child: Container(
                                  width: kDesktopFileTransferNameColWidth,
                                  child: Tooltip(
                                    waitDuration: Duration(milliseconds: 500),
                                    message: entry.name,
                                    child: Row(children: [
                                      entry.isDrive
                                          ? Image(
                                                  image: iconHardDrive,
                                                  fit: BoxFit.scaleDown,
                                                  color: Theme.of(context)
                                                      .iconTheme
                                                      .color
                                                      ?.withOpacity(0.7))
                                              .paddingAll(4)
                                          : Icon(
                                              entry.isFile
                                                  ? Icons.feed_outlined
                                                  : Icons.folder,
                                              size: 20,
                                              color: Theme.of(context)
                                                  .iconTheme
                                                  .color
                                                  ?.withOpacity(0.7),
                                            ).marginSymmetric(horizontal: 2),
                                      Expanded(
                                          child: Text(entry.name.nonBreaking,
                                              overflow: TextOverflow.ellipsis))
                                    ]),
                                  )),
                              onTap: () {
                                final items = getSelectedItems(isLocal);
                                // handle double click
                                if (_checkDoubleClick(entry)) {
                                  openDirectory(entry.path, isLocal: isLocal);
                                  items.clear();
                                  return;
                                }
                                _onSelectedChanged(
                                    items, filteredEntries, entry, isLocal);
                              },
                            ),
                            GestureDetector(
                                child: SizedBox(
                              width: kDesktopFileTransferModifiedColWidth,
                              child: Tooltip(
                                  waitDuration: Duration(milliseconds: 500),
                                  message: lastModifiedStr,
                                  child: Text(
                                    lastModifiedStr,
                                    style: TextStyle(
                                        fontSize: 12, color: MyTheme.darkGray),
                                  )),
                            )),
                            GestureDetector(
                                child: Tooltip(
                                    waitDuration: Duration(milliseconds: 500),
                                    message: sizeStr,
                                    child: Text(
                                      sizeStr,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: MyTheme.darkGray),
                                    ))),
                          ]),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(growable: false);

            return Column(
              children: [
                // Header
                _buildFileBrowserHeader(context, isLocal),
                // Body
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemExtent: kDesktopFileTransferRowHeight,
                    itemBuilder: (context, index) {
                      return rows[index];
                    },
                    itemCount: rows.length,
                  ),
                ),
              ],
            );
          },
          isLocal ? _searchTextLocal : _searchTextRemote,
        ),
      ),
    );
  }

  void _jumpToEntry(bool isLocal, Entry entry,
      ScrollController scrollController, double rowHeight, String buffer) {
    final entries = model.getCurrentDir(isLocal).entries;
    final index = entries.indexOf(entry);
    if (index == -1) {
      debugPrint("entry is not valid: ${entry.path}");
    }
    final selectedEntries = getSelectedItems(isLocal);
    final searchResult =
        entries.where((element) => element.name.startsWith(buffer));
    selectedEntries.clear();
    if (searchResult.isEmpty) {
      return;
    }
    final offset = min(
        max(scrollController.position.minScrollExtent,
            entries.indexOf(searchResult.first) * rowHeight),
        scrollController.position.maxScrollExtent);
    scrollController.jumpTo(offset);
    setState(() {
      selectedEntries.add(isLocal, searchResult.first);
      debugPrint("focused on ${searchResult.first.name}");
    });
  }

  void _onSelectedChanged(SelectedItems selectedItems, List<Entry> entries,
      Entry entry, bool isLocal) {
    final isCtrlDown = RawKeyboard.instance.keysPressed
        .contains(LogicalKeyboardKey.controlLeft);
    final isShiftDown =
        RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shiftLeft);
    if (isCtrlDown) {
      if (selectedItems.contains(entry)) {
        selectedItems.remove(entry);
      } else {
        selectedItems.add(isLocal, entry);
      }
    } else if (isShiftDown) {
      final List<int> indexGroup = [];
      for (var selected in selectedItems.items) {
        indexGroup.add(entries.indexOf(selected));
      }
      indexGroup.add(entries.indexOf(entry));
      indexGroup.removeWhere((e) => e == -1);
      final maxIndex = indexGroup.reduce(max);
      final minIndex = indexGroup.reduce(min);
      selectedItems.clear();
      entries
          .getRange(minIndex, maxIndex + 1)
          .forEach((e) => selectedItems.add(isLocal, e));
    } else {
      selectedItems.clear();
      selectedItems.add(isLocal, entry);
    }
    setState(() {});
  }

  bool _checkDoubleClick(Entry entry) {
    final current = DateTime.now().millisecondsSinceEpoch;
    final elapsed = current - _lastClickTime;
    _lastClickTime = current;
    if (_lastClickEntry == entry) {
      if (elapsed < bind.getDoubleClickTime()) {
        return true;
      }
    } else {
      _lastClickEntry = entry;
    }
    return false;
  }

  /// transfer status list
  /// watch transfer status
  Widget statusList() {
    return PreferredSize(
        preferredSize: const Size(200, double.infinity),
        child: Container(
          margin: const EdgeInsets.only(top: 16.0, bottom: 16.0, right: 16.0),
          padding: const EdgeInsets.all(8.0),
          decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
          child: Obx(
            () => ListView.builder(
              controller: ScrollController(),
              itemBuilder: (BuildContext context, int index) {
                final item = model.jobTable[index];
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Transform.rotate(
                            angle: item.isRemote ? pi : 0,
                            child: const Icon(Icons.send)),
                        const SizedBox(
                          width: 16.0,
                        ),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Tooltip(
                                  waitDuration: Duration(milliseconds: 500),
                                  message: item.jobName,
                                  child: Text(
                                    item.jobName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  )),
                              Wrap(
                                children: [
                                  Text(
                                      '${item.display()} ${max(0, item.fileNum)}/${item.fileCount} '),
                                  Text(
                                      '${translate("files")} ${readableFileSize(item.totalSize.toDouble())} '),
                                  Offstage(
                                      offstage:
                                          item.state != JobState.inProgress,
                                      child: Text(
                                          '${"${readableFileSize(item.speed)}/s"} ')),
                                  Offstage(
                                    offstage: item.totalSize <= 0,
                                    child: Text(
                                        '${(item.finishedSize.toDouble() * 100 / item.totalSize.toDouble()).toStringAsFixed(2)}%'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Offstage(
                              offstage: item.state != JobState.paused,
                              child: IconButton(
                                  onPressed: () {
                                    model.resumeJob(item.id);
                                  },
                                  splashRadius: kDesktopIconButtonSplashRadius,
                                  icon: const Icon(Icons.restart_alt_rounded)),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close),
                              splashRadius: 1,
                              onPressed: () {
                                model.jobTable.removeAt(index);
                                model.cancelJob(item.id);
                              },
                            ),
                          ],
                        )
                      ],
                    ),
                    SizedBox(
                      height: 8.0,
                    ),
                    Divider(
                      height: 2.0,
                    )
                  ],
                );
              },
              itemCount: model.jobTable.length,
            ),
          ),
        ));
  }

  Widget headTools(bool isLocal) {
    final locationStatus =
        isLocal ? _locationStatusLocal : _locationStatusRemote;
    final locationFocus = isLocal ? _locationNodeLocal : _locationNodeRemote;
    final selectedItems = getSelectedItems(isLocal);
    return Container(
        child: Column(
      children: [
        // symbols
        PreferredSize(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(color: Colors.blue),
                    padding: EdgeInsets.all(8.0),
                    child: FutureBuilder<String>(
                        future: bind.sessionGetPlatform(
                            id: _ffi.id, isRemote: !isLocal),
                        builder: (context, snapshot) {
                          if (snapshot.hasData && snapshot.data!.isNotEmpty) {
                            return getPlatformImage('${snapshot.data}');
                          } else {
                            return CircularProgressIndicator(
                              color: Colors.white,
                            );
                          }
                        })),
                Text(isLocal
                        ? translate("Local Computer")
                        : translate("Remote Computer"))
                    .marginOnly(left: 8.0)
              ],
            ),
            preferredSize: Size(double.infinity, 70)),
        // buttons
        Row(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  splashRadius: kDesktopIconButtonSplashRadius,
                  onPressed: () {
                    selectedItems.clear();
                    model.goBack(isLocal: isLocal);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  splashRadius: kDesktopIconButtonSplashRadius,
                  onPressed: () {
                    selectedItems.clear();
                    model.goToParentDirectory(isLocal: isLocal);
                  },
                ),
              ],
            ),
            Expanded(
                child: GestureDetector(
              onTap: () {
                locationStatus.value =
                    locationStatus.value == LocationStatus.bread
                        ? LocationStatus.pathLocation
                        : LocationStatus.bread;
                Future.delayed(Duration.zero, () {
                  if (locationStatus.value == LocationStatus.pathLocation) {
                    locationFocus.requestFocus();
                  }
                });
              },
              child: Obx(() => Container(
                  decoration: BoxDecoration(
                      border: Border.all(
                          color: locationStatus.value == LocationStatus.bread
                              ? Colors.black12
                              : Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withOpacity(0.5))),
                  child: Row(
                    children: [
                      Expanded(
                          child: locationStatus.value == LocationStatus.bread
                              ? buildBread(isLocal)
                              : buildPathLocation(isLocal)),
                    ],
                  ))),
            )),
            Obx(() {
              switch (locationStatus.value) {
                case LocationStatus.bread:
                  return IconButton(
                      onPressed: () {
                        locationStatus.value = LocationStatus.fileSearchBar;
                        final focusNode =
                            isLocal ? _locationNodeLocal : _locationNodeRemote;
                        Future.delayed(
                            Duration.zero, () => focusNode.requestFocus());
                      },
                      splashRadius: kDesktopIconButtonSplashRadius,
                      icon: Icon(Icons.search));
                case LocationStatus.pathLocation:
                  return IconButton(
                      color: Theme.of(context).disabledColor,
                      onPressed: null,
                      splashRadius: kDesktopIconButtonSplashRadius,
                      icon: Icon(Icons.close));
                case LocationStatus.fileSearchBar:
                  return IconButton(
                      color: Theme.of(context).disabledColor,
                      onPressed: () {
                        onSearchText("", isLocal);
                        locationStatus.value = LocationStatus.bread;
                      },
                      splashRadius: 1,
                      icon: Icon(Icons.close));
              }
            }),
            IconButton(
                onPressed: () {
                  model.refresh(isLocal: isLocal);
                },
                splashRadius: kDesktopIconButtonSplashRadius,
                icon: const Icon(Icons.refresh)),
          ],
        ),
        Row(
          textDirection: isLocal ? TextDirection.ltr : TextDirection.rtl,
          children: [
            Expanded(
              child: Row(
                mainAxisAlignment:
                    isLocal ? MainAxisAlignment.start : MainAxisAlignment.end,
                children: [
                  IconButton(
                    onPressed: () {
                      model.goHome(isLocal: isLocal);
                    },
                    icon: const Icon(Icons.home_outlined),
                    splashRadius: kDesktopIconButtonSplashRadius,
                  ),
                  IconButton(
                      onPressed: () {
                        final name = TextEditingController();
                        _ffi.dialogManager.show((setState, close) {
                          submit() {
                            if (name.value.text.isNotEmpty) {
                              model.createDir(
                                  PathUtil.join(
                                      model.getCurrentDir(isLocal).path,
                                      name.value.text,
                                      model.getCurrentIsWindows(isLocal)),
                                  isLocal: isLocal);
                              close();
                            }
                          }

                          cancel() => close(false);
                          return CustomAlertDialog(
                            title: Text(translate("Create Folder")),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextFormField(
                                  decoration: InputDecoration(
                                    labelText: translate(
                                        "Please enter the folder name"),
                                  ),
                                  controller: name,
                                  autofocus: true,
                                ),
                              ],
                            ),
                            actions: [
                              dialogButton("Cancel",
                                  onPressed: cancel, isOutline: true),
                              dialogButton("OK", onPressed: submit)
                            ],
                            onSubmit: submit,
                            onCancel: cancel,
                          );
                        });
                      },
                      splashRadius: kDesktopIconButtonSplashRadius,
                      icon: const Icon(Icons.create_new_folder_outlined)),
                  IconButton(
                      onPressed: validItems(selectedItems)
                          ? () async {
                              await (model.removeAction(selectedItems,
                                  isLocal: isLocal));
                              selectedItems.clear();
                            }
                          : null,
                      splashRadius: kDesktopIconButtonSplashRadius,
                      icon: const Icon(Icons.delete_forever_outlined)),
                  menu(isLocal: isLocal),
                ],
              ),
            ),
            TextButton.icon(
                onPressed: validItems(selectedItems)
                    ? () {
                        model.sendFiles(selectedItems, isRemote: !isLocal);
                        selectedItems.clear();
                      }
                    : null,
                icon: Transform.rotate(
                  angle: isLocal ? 0 : pi,
                  child: const Icon(
                    Icons.send,
                  ),
                ),
                label: Text(
                  isLocal ? translate('Send') : translate('Receive'),
                )),
          ],
        ).marginOnly(top: 8.0)
      ],
    ));
  }

  bool validItems(SelectedItems items) {
    if (items.length > 0) {
      // exclude DirDrive type
      return items.items.any((item) => !item.isDrive);
    }
    return false;
  }

  @override
  bool get wantKeepAlive => true;

  void onLocalLocationFocusChanged() {
    debugPrint("focus changed on local");
    if (_locationNodeLocal.hasFocus) {
      // ignore
    } else {
      // lost focus, change to bread
      if (_locationStatusLocal.value != LocationStatus.fileSearchBar) {
        _locationStatusLocal.value = LocationStatus.bread;
      }
    }
  }

  void onRemoteLocationFocusChanged() {
    debugPrint("focus changed on remote");
    if (_locationNodeRemote.hasFocus) {
      // ignore
    } else {
      // lost focus, change to bread
      if (_locationStatusRemote.value != LocationStatus.fileSearchBar) {
        _locationStatusRemote.value = LocationStatus.bread;
      }
    }
  }

  Widget buildBread(bool isLocal) {
    final items = getPathBreadCrumbItems(isLocal, (list) {
      var path = "";
      for (var item in list) {
        path = PathUtil.join(path, item, model.getCurrentIsWindows(isLocal));
      }
      openDirectory(path, isLocal: isLocal);
    });
    final locationBarKey = getLocationBarKey(isLocal);

    return items.isEmpty
        ? Offstage()
        : Row(
            key: locationBarKey,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
                Expanded(
                    child: Listener(
                        // handle mouse wheel
                        onPointerSignal: (e) {
                          if (e is PointerScrollEvent) {
                            final sc = getBreadCrumbScrollController(isLocal);
                            final scale = Platform.isWindows ? 2 : 4;
                            sc.jumpTo(sc.offset + e.scrollDelta.dy / scale);
                          }
                        },
                        child: BreadCrumb(
                          items: items,
                          divider: Icon(Icons.chevron_right),
                          overflow: ScrollableOverflow(
                              controller:
                                  getBreadCrumbScrollController(isLocal)),
                        ))),
                ActionIcon(
                  message: "",
                  icon: Icons.arrow_drop_down,
                  onTap: () async {
                    final renderBox = locationBarKey.currentContext
                        ?.findRenderObject() as RenderBox;
                    locationBarKey.currentContext?.size;

                    final size = renderBox.size;
                    final offset = renderBox.localToGlobal(Offset.zero);

                    final x = offset.dx;
                    final y = offset.dy + size.height + 1;

                    final isPeerWindows = model.getCurrentIsWindows(isLocal);
                    final List<MenuEntryBase> menuItems = [
                      MenuEntryButton(
                          childBuilder: (TextStyle? style) => isPeerWindows
                              ? buildWindowsThisPC(style)
                              : Text(
                                  '/',
                                  style: style,
                                ),
                          proc: () {
                            openDirectory('/', isLocal: isLocal);
                          },
                          dismissOnClicked: true),
                      MenuEntryDivider()
                    ];
                    if (isPeerWindows) {
                      var loadingTag = "";
                      if (!isLocal) {
                        loadingTag = _ffi.dialogManager.showLoading("Waiting");
                      }
                      try {
                        final fd =
                            await model.fetchDirectory("/", isLocal, isLocal);
                        for (var entry in fd.entries) {
                          menuItems.add(MenuEntryButton(
                              childBuilder: (TextStyle? style) =>
                                  Row(children: [
                                    Image(
                                        image: iconHardDrive,
                                        fit: BoxFit.scaleDown,
                                        color: Theme.of(context)
                                            .iconTheme
                                            .color
                                            ?.withOpacity(0.7)),
                                    SizedBox(width: 10),
                                    Text(
                                      entry.name,
                                      style: style,
                                    )
                                  ]),
                              proc: () {
                                openDirectory('${entry.name}\\',
                                    isLocal: isLocal);
                              },
                              dismissOnClicked: true));
                        }
                      } catch (e) {
                        debugPrint("buildBread fetchDirectory err=$e");
                      } finally {
                        if (!isLocal) {
                          _ffi.dialogManager.dismissByTag(loadingTag);
                        }
                      }
                    }
                    menuItems.add(MenuEntryDivider());
                    mod_menu.showMenu(
                        context: context,
                        position: RelativeRect.fromLTRB(x, y, x, y),
                        elevation: 4,
                        items: menuItems
                            .map((e) => e.build(
                                context,
                                MenuConfig(
                                    commonColor:
                                        CustomPopupMenuTheme.commonColor,
                                    height: CustomPopupMenuTheme.height,
                                    dividerHeight:
                                        CustomPopupMenuTheme.dividerHeight,
                                    boxWidth: size.width)))
                            .expand((i) => i)
                            .toList());
                  },
                  iconSize: 20,
                )
              ]);
  }

  Widget buildWindowsThisPC([TextStyle? textStyle]) {
    final color = Theme.of(context).iconTheme.color?.withOpacity(0.7);
    return Row(children: [
      Icon(Icons.computer, size: 20, color: color),
      SizedBox(width: 10),
      Text(translate('This PC'), style: textStyle)
    ]);
  }

  List<BreadCrumbItem> getPathBreadCrumbItems(
      bool isLocal, void Function(List<String>) onPressed) {
    final path = model.getCurrentDir(isLocal).path;
    final breadCrumbList = List<BreadCrumbItem>.empty(growable: true);
    final isWindows = model.getCurrentIsWindows(isLocal);
    if (isWindows && path == '/') {
      breadCrumbList.add(BreadCrumbItem(
          content: TextButton(
                  child: buildWindowsThisPC(),
                  style: ButtonStyle(
                      minimumSize: MaterialStateProperty.all(Size(0, 0))),
                  onPressed: () => onPressed(['/']))
              .marginSymmetric(horizontal: 4)));
    } else {
      final list = PathUtil.split(path, isWindows);
      breadCrumbList.addAll(list.asMap().entries.map((e) => BreadCrumbItem(
          content: TextButton(
                  child: Text(e.value),
                  style: ButtonStyle(
                      minimumSize: MaterialStateProperty.all(Size(0, 0))),
                  onPressed: () => onPressed(list.sublist(0, e.key + 1)))
              .marginSymmetric(horizontal: 4))));
    }
    return breadCrumbList;
  }

  breadCrumbScrollToEnd(bool isLocal) {
    Future.delayed(Duration(milliseconds: 200), () {
      final breadCrumbScroller = getBreadCrumbScrollController(isLocal);
      if (breadCrumbScroller.hasClients) {
        breadCrumbScroller.animateTo(
            breadCrumbScroller.position.maxScrollExtent,
            duration: Duration(milliseconds: 200),
            curve: Curves.fastLinearToSlowEaseIn);
      }
    });
  }

  Widget buildPathLocation(bool isLocal) {
    final searchTextObs = isLocal ? _searchTextLocal : _searchTextRemote;
    final locationStatus =
        isLocal ? _locationStatusLocal : _locationStatusRemote;
    final focusNode = isLocal ? _locationNodeLocal : _locationNodeRemote;
    final text = locationStatus.value == LocationStatus.pathLocation
        ? model.getCurrentDir(isLocal).path
        : searchTextObs.value;
    final textController = TextEditingController(text: text)
      ..selection = TextSelection.collapsed(offset: text.length);
    return Row(children: [
      Icon(
        locationStatus.value == LocationStatus.pathLocation
            ? Icons.folder
            : Icons.search,
        color: Theme.of(context).hintColor,
      ).paddingSymmetric(horizontal: 2),
      Expanded(
          child: TextField(
        focusNode: focusNode,
        decoration: InputDecoration(
            border: InputBorder.none,
            isDense: true,
            prefix: Padding(padding: EdgeInsets.only(left: 4.0))),
        controller: textController,
        onSubmitted: (path) {
          openDirectory(path, isLocal: isLocal);
        },
        onChanged: locationStatus.value == LocationStatus.fileSearchBar
            ? (searchText) => onSearchText(searchText, isLocal)
            : null,
      ))
    ]);
  }

  onSearchText(String searchText, bool isLocal) {
    if (isLocal) {
      _localSelectedItems.clear();
      _searchTextLocal.value = searchText;
    } else {
      _remoteSelectedItems.clear();
      _searchTextRemote.value = searchText;
    }
  }

  openDirectory(String path, {bool isLocal = false}) {
    model.openDirectory(path, isLocal: isLocal);
  }

  void handleDragDone(DropDoneDetails details, bool isLocal) {
    if (isLocal) {
      // ignore local
      return;
    }
    var items = SelectedItems();
    for (var file in details.files) {
      final f = File(file.path);
      items.add(
          true,
          Entry()
            ..path = file.path
            ..name = file.name
            ..size =
                FileSystemEntity.isDirectorySync(f.path) ? 0 : f.lengthSync());
    }
    model.sendFiles(items, isRemote: false);
  }

  void refocusKeyboardListener(bool isLocal) {
    Future.delayed(Duration.zero, () {
      if (isLocal) {
        _keyboardNodeLocal.requestFocus();
      } else {
        _keyboardNodeRemote.requestFocus();
      }
    });
  }

  Widget headerItemFunc(
      double? width, SortBy sortBy, String name, bool isLocal) {
    final headerTextStyle =
        Theme.of(context).dataTableTheme.headingTextStyle ?? TextStyle();
    return ObxValue<Rx<bool?>>(
        (ascending) => InkWell(
              onTap: () {
                if (ascending.value == null) {
                  ascending.value = true;
                } else {
                  ascending.value = !ascending.value!;
                }
                model.changeSortStyle(sortBy,
                    isLocal: isLocal, ascending: ascending.value!);
              },
              child: SizedBox(
                width: width,
                height: kDesktopFileTransferHeaderHeight,
                child: Row(
                  children: [
                    Text(
                      name,
                      style: headerTextStyle,
                    ).marginSymmetric(
                        horizontal: sortBy == SortBy.name ? 4 : 0.0),
                    ascending.value != null
                        ? Icon(ascending.value!
                            ? Icons.arrow_upward
                            : Icons.arrow_downward)
                        : const Offstage()
                  ],
                ),
              ),
            ), () {
      if (model.getSortStyle(isLocal) == sortBy) {
        return model.getSortAscending(isLocal).obs;
      } else {
        return Rx<bool?>(null);
      }
    }());
  }

  Widget _buildFileBrowserHeader(BuildContext context, bool isLocal) {
    return Row(
      children: [
        headerItemFunc(kDesktopFileTransferNameColWidth, SortBy.name,
            translate("Name"), isLocal),
        headerItemFunc(kDesktopFileTransferModifiedColWidth, SortBy.modified,
            translate("Modified"), isLocal),
        Expanded(
            child:
                headerItemFunc(null, SortBy.size, translate("Size"), isLocal))
      ],
    );
  }
}
