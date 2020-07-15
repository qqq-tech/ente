import 'dart:async';
import 'dart:collection';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:photos/events/event.dart';
import 'package:photos/models/file.dart';
import 'package:photos/ui/detail_page.dart';
import 'package:photos/ui/loading_widget.dart';
import 'package:photos/ui/sync_indicator.dart';
import 'package:photos/ui/thumbnail_widget.dart';
import 'package:photos/utils/date_time_util.dart';
import 'package:pull_to_refresh/pull_to_refresh.dart';

class Gallery extends StatefulWidget {
  final List<File> Function() syncLoader;
  final Future<List<File>> Function(int offset, int limit) asyncLoader;
  // TODO: Verify why the event is necessary when calling loader post onRefresh
  // should have done the job.
  final Stream<Event> reloadEvent;
  final Future<void> Function() onRefresh;
  final fileSelectionChangeListeners = new List<Function(Set<File>)>();
  final String tagPrefix;

  Gallery({
    this.syncLoader,
    this.asyncLoader,
    this.reloadEvent,
    this.onRefresh,
    this.tagPrefix,
  });

  _GalleryState state;

  @override
  _GalleryState createState() {
    state = _GalleryState();
    return state;
  }

  void clearSelection() {
    state.clearSelection();
  }
}

class _GalleryState extends State<Gallery> {
  static final int kLoadLimit = 100;
  static final int kEagerLoadTrigger = 10;

  final Logger _logger = Logger("Gallery");
  final List<List<File>> _collatedFiles = List<List<File>>();

  ScrollController _scrollController = ScrollController();
  bool _requiresLoad = false;
  bool _hasLoadedAll = false;
  double _scrollOffset = 0;
  Set<File> _selectedFiles = Set<File>();
  List<File> _files;
  RefreshController _refreshController = RefreshController();

  @override
  void initState() {
    _requiresLoad = true;
    if (widget.reloadEvent != null) {
      widget.reloadEvent.listen((event) {
        setState(() {
          _requiresLoad = true;
        });
      });
    }
    super.initState();
  }

  void clearSelection() {
    setState(() {
      _selectedFiles = Set<File>();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_requiresLoad) {
      return _onDataLoaded();
    }
    if (widget.syncLoader != null) {
      _files = widget.syncLoader();
      return _onDataLoaded();
    }
    return FutureBuilder<List<File>>(
      future: widget.asyncLoader(0, kLoadLimit),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          _requiresLoad = false;
          _files = snapshot.data;
          return _onDataLoaded();
        } else if (snapshot.hasError) {
          _requiresLoad = false;
          return Center(child: Text(snapshot.error.toString()));
        } else {
          return Center(child: loadWidget);
        }
      },
    );
  }

  Widget _onDataLoaded() {
    _logger.info("Loaded " + _files.length.toString());
    if (_files.isEmpty) {
      return Center(child: Text("Nothing to see here! 👀"));
    }
    _collateFiles();
    _scrollController = ScrollController(
      initialScrollOffset: _scrollOffset,
    );
    final list = ListView.builder(
      itemCount: _collatedFiles.length + 1, // h4ck to load the next set
      itemBuilder: _buildListItem,
      controller: _scrollController,
      cacheExtent: 1000,
    );
    if (widget.onRefresh != null) {
      return SmartRefresher(
        controller: _refreshController,
        child: list,
        header: SyncIndicator(_refreshController),
        onRefresh: () {
          widget.onRefresh().then((_) {
            _refreshController.refreshCompleted();
            setState(() {
              _requiresLoad = true;
            });
          }).catchError((e) {
            _refreshController.refreshFailed();
            setState(() {});
          });
        },
      );
    } else {
      return list;
    }
  }

  Widget _buildListItem(BuildContext context, int index) {
    if (_shouldLoadNextItems(index)) {
      // Eagerly load next batch
      _loadNextItems();
    }
    if (index == _collatedFiles.length) {
      if (_hasLoadedAll || widget.asyncLoader == null) {
        return Container();
      }
      return loadWidget;
    }
    var files = _collatedFiles[index];
    return Column(
      children: <Widget>[_getDay(files[0].creationTime), _getGallery(files)],
    );
  }

  bool _shouldLoadNextItems(int index) =>
      index == _collatedFiles.length - kEagerLoadTrigger;

  void _loadNextItems() {
    widget.asyncLoader(_files.length, 100).then((files) {
      setState(() {
        _scrollOffset = _scrollController.offset;
        if (files.length == 0) {
          _hasLoadedAll = true;
        }
        _files.addAll(files);
      });
    });
  }

  Widget _getDay(int timestamp) {
    return Container(
      padding: const EdgeInsets.all(8.0),
      alignment: Alignment.centerLeft,
      child: Text(
        getDayAndMonth(DateTime.fromMicrosecondsSinceEpoch(timestamp)),
        style: TextStyle(fontSize: 16),
      ),
    );
  }

  Widget _getGallery(List<File> files) {
    return GridView.builder(
      shrinkWrap: true,
      padding: EdgeInsets.only(bottom: 12),
      physics:
          NeverScrollableScrollPhysics(), // to disable GridView's scrolling
      itemBuilder: (context, index) {
        return _buildFile(context, files[index]);
      },
      itemCount: files.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
      ),
    );
  }

  Widget _buildFile(BuildContext context, File file) {
    return GestureDetector(
      onTap: () {
        if (_selectedFiles.isNotEmpty) {
          _selectFile(file);
        } else {
          _routeToDetailPage(file, context);
        }
      },
      onLongPress: () {
        HapticFeedback.lightImpact();
        _selectFile(file);
      },
      child: Container(
        margin: const EdgeInsets.all(2.0),
        decoration: BoxDecoration(
          border: _selectedFiles.contains(file)
              ? Border.all(width: 4.0, color: Colors.blue)
              : null,
        ),
        child: Hero(
          tag: widget.tagPrefix + file.tag(),
          child: ThumbnailWidget(file),
        ),
      ),
    );
  }

  void _selectFile(File file) {
    setState(() {
      if (_selectedFiles.contains(file)) {
        _selectedFiles.remove(file);
      } else {
        _selectedFiles.add(file);
      }
      for (final listener in widget.fileSelectionChangeListeners) {
        listener.call(_selectedFiles);
      }
    });
  }

  void _routeToDetailPage(File file, BuildContext context) {
    final page = DetailPage(
      _files,
      _files.indexOf(file),
      widget.tagPrefix,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (BuildContext context) {
          return page;
        },
      ),
    );
  }

  void _collateFiles() {
    final dailyFiles = List<File>();
    final collatedFiles = List<List<File>>();
    for (int index = 0; index < _files.length; index++) {
      if (index > 0 &&
          !_areFilesFromSameDay(_files[index], _files[index - 1])) {
        var collatedDailyFiles = List<File>();
        collatedDailyFiles.addAll(dailyFiles);
        collatedFiles.add(collatedDailyFiles);
        dailyFiles.clear();
      }
      dailyFiles.add(_files[index]);
    }
    if (dailyFiles.isNotEmpty) {
      collatedFiles.add(dailyFiles);
    }
    _collatedFiles.clear();
    _collatedFiles.addAll(collatedFiles);
  }

  bool _areFilesFromSameDay(File first, File second) {
    var firstDate = DateTime.fromMicrosecondsSinceEpoch(first.creationTime);
    var secondDate = DateTime.fromMicrosecondsSinceEpoch(second.creationTime);
    return firstDate.year == secondDate.year &&
        firstDate.month == secondDate.month &&
        firstDate.day == secondDate.day;
  }
}
